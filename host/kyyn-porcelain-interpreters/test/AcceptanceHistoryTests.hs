{-# LANGUAGE DataKinds #-}
module AcceptanceHistoryTests (acceptanceHistoryTests) where

import Control.Monad (unless)
import qualified Data.ByteString.Char8 as Bytes
import Effectful (Eff, IOE, runEff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Evolution
import Kyyn.Domain.FileTree
import Kyyn.Domain.Git
import Kyyn.Domain.KnowledgeBase
import Kyyn.Domain.Path
import Kyyn.Domain.Workspace
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Capability.Git
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.Git
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.Porcelain.Capability.EvolutionStore
import Kyyn.Porcelain.Capability.RootOpening (RootOpening)
import Kyyn.Porcelain.Capability.WorkspaceStore
import Kyyn.Porcelain.Interpreter.EvolutionStore
import Kyyn.Porcelain.Interpreter.RootStore
import Kyyn.Porcelain.Interpreter.WorkspaceStore
import System.Directory (findExecutable)
import System.IO.Temp (withSystemTempDirectory)

acceptanceHistoryTests :: IO ()
acceptanceHistoryTests = withSystemTempDirectory "kyyn-acceptance-history" $ \directory -> do
  executable <- findExecutable "git" >>= maybe (fail "Git required") pure
  scope <- right (directoryScope directory)
  identity <- right (evolutionId "e001")
  let path = either error id . relativePath
      tree = either error id . fileTree
      empty = tree []
      repo = Repository scope
      kb = KnowledgeBase repo (Subtree (path "nested/kb"))
      archivePath = Subtree (path "nested/kb/evolutions/e001")
      manifestPath = path "nested/kb/evolutions/e001/manifest.dhall"
      git :: Eff '[Git, Process.ProcessExecution, Failure, IOE] a -> IO a
      git action = runEff (runFailure (runProcessExecutionIO (runGit executable action))) >>= right
      process args = do
        result <- runEff . runFailure . runProcessExecutionIO $ Process.withProcess
          (Process.ProcessSpec executable (["-c","user.name=Fixture","-c","user.email=fixture@example.invalid"] ++ args)
            directory [("PATH",""),("LC_ALL","C")]) $ do
            Process.closeStdin
            output <- Process.collectStdout
            status <- Process.awaitExit
            pure (output,status)
        case result of
          Right (output,Process.ProcessExit 0 _) -> pure output
          _ -> fail (show result)
      metadata message = CommitMetadata (CommitIdentity "Fixture" "fixture@example.invalid" "1700000000 +0000")
        (CommitIdentity "Fixture" "fixture@example.invalid" "1700000000 +0000") message
      archive before state = right $ runPureEff . runDhallHandling . runWorkspaceStore $
        encodeWorkspaceSnapshot (WorkspaceSnapshot (WorkspaceManifest before "Example" "Reason" state []) empty empty empty empty)
      commit parent contents message = git (createCommit repo (GitTree [(archivePath,contents)]) parent (metadata message))
      lookupAt revision = runEff . runFailure . runProcessExecutionIO . runGit executable . noFiles
        . runDhallHandling . runRootStore . runWorkspaceStore . noOpening . runEvolutionStore $
          findAcceptance kb identity revision
      expect revision result = do
        actual <- lookupAt revision >>= right >>= right
        unless (actual == result) (fail ("Wrong acceptance at " ++ show revision ++ ": " ++ show actual))
      merge left rightParent contents = do
        rootTree <- process ["show","-s","--format=%T",revisionName contents]
        output <- process ["commit-tree",Bytes.unpack (Bytes.strip rootTree),"-p",revisionName left,
          "-p",revisionName rightParent,"-m","Merge fixture"]
        right (gitRevision (Bytes.unpack (Bytes.strip output)))
  _ <- process ["init","-q","--ref-format=files","-b","main"]
  _ <- process ["commit","--allow-empty","-qm","Initial"]
  base <- git (resolveRevision repo "HEAD") >>= right
  parents <- git (readCommitParents repo base) >>= right
  unless (null parents) (fail "Initial commit unexpectedly had parents")
  absent <- git (readFileAt repo base manifestPath) >>= right
  unless (absent == Nothing) (fail "Absent Git file did not return Nothing")
  expect base Nothing
  draftFiles <- archive base Draft
  draft <- commit base draftFiles "Draft"
  expect draft Nothing
  acceptedFiles <- archive draft Accepted
  accepted <- commit draft acceptedFiles "Accept"
  expect accepted (Just accepted)
  acceptedParents <- git (readCommitParents repo accepted) >>= right
  unless (acceptedParents == [draft]) (fail "Commit parents were not exact")
  later <- git (createCommit repo (GitTree []) accepted (metadata "Later unrelated commit"))
  expect later (Just accepted)
  reverted <- commit later draftFiles "Revert acceptance"
  expect reverted Nothing
  againFiles <- archive reverted Accepted
  again <- commit reverted againFiles "Re-accept"
  expect again (Just again)
  removed <- commit again empty "Remove archive"
  expect removed Nothing
  left <- git (createCommit repo (GitTree []) draft (metadata "Unrelated first parent"))
  merged <- merge left later later
  expect merged (Just accepted)
  mergeParents <- git (readCommitParents repo merged) >>= right
  unless (mergeParents == [left,later]) (fail "Merge parent order/membership changed")
  sibling <- commit draft acceptedFiles "Other acceptance from same base"
  ambiguous <- merge accepted sibling accepted
  lookupAt ambiguous >>= right >>= \result -> case result of
    Left [Diagnostic Error "evolution.acceptance-history" _ _] -> pure ()
    _ -> fail ("Ambiguous acceptance was guessed: " ++ show result)
  fabricatedFiles <- archive base Accepted
  fabricated <- commit draft fabricatedFiles "Wrong Before parent"
  lookupAt fabricated >>= right >>= \result -> case result of
    Left [Diagnostic Error "evolution.acceptance-history" _ _] -> pure ()
    _ -> fail "Malformed acceptance history returned a commit"
  malformed <- commit base (tree [(path "manifest.dhall","True")]) "Malformed archive"
  lookupAt malformed >>= right >>= \result -> case result of
    Left _ -> pure ()
    _ -> fail "Malformed archive became missing acceptance"
  directoryResult <- git (readFileAt repo accepted (path "nested/kb/evolutions/e001")) >>= rightResult
  unless directoryResult (fail "Directory was treated as a file")
  unknown <- right (gitRevision (replicate 40 'f'))
  git (readCommitParents repo unknown) >>= rightResult >>= \rejected -> unless rejected (fail "Unknown commit silently had no parents")
  headAfter <- git (resolveRevision repo "HEAD") >>= right
  unless (headAfter == base) (fail "History inspection moved HEAD")
  putStrLn "Acceptance lookup identifies introductions across all parents, reverts, reacceptance and ambiguous histories."

noFiles :: Eff (FileSystem : es) a -> Eff es a
noFiles = interpret $ \_ _ -> error "Acceptance lookup read the live checkout or candidate storage"

noOpening :: Eff (RootOpening : es) a -> Eff es a
noOpening = interpret $ \_ _ -> error "Acceptance lookup loaded or compiled a root"

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

rightResult :: Either e a -> IO Bool
rightResult = pure . either (const True) (const False)
