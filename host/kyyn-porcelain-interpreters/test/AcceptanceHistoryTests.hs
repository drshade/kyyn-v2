{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module AcceptanceHistoryTests (acceptanceHistoryTests) where

import Control.Monad (unless, forM_)
import qualified Data.ByteString.Char8 as Bytes
import Effectful (Eff, IOE, (:>), runEff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret, send)
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Evolution
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Domain.FileTree
import Kyyn.Domain.Git
import Kyyn.Domain.KnowledgeBase
import Kyyn.Domain.Path
import Kyyn.Domain.Workspace
import qualified Kyyn.Domain.Workspace as Workspace
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import Kyyn.Plumbing.Capability.Git
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Git
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.Porcelain.Capability.EvolutionStore
import Kyyn.Porcelain.Capability.RootOpening (RootOpening)
import Kyyn.Porcelain.Capability.RootStore (RootStore)
import Kyyn.Porcelain.Capability.WorkspaceStore
import Kyyn.Porcelain.Interpreter.EvolutionStore
import Kyyn.Porcelain.Interpreter.RootStore
import Kyyn.Porcelain.Interpreter.WorkspaceStore
import System.Directory (findExecutable, createDirectoryIfMissing, removeFile, doesPathExist)
import System.FilePath ((</>), takeDirectory)
import System.IO.Temp (withSystemTempDirectory)

type LifecycleEffects = '[EvolutionStore, RootOpening, WorkspaceStore, RootStore, DhallHandling,
  FileSystem, FileSystem, Git, Process.ProcessExecution, Failure, IOE]

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
  let lifecycle :: Eff LifecycleEffects a -> IO (Either OperationalFailure a)
      lifecycle action = runEff . runFailure . runProcessExecutionIO . runGit executable
        . runFileSystemIO scope . shallowFiles . runDhallHandling . runRootStore
        . runWorkspaceStore . noOpening . runEvolutionStore $ action
      runLifecycle :: Eff LifecycleEffects a -> IO a
      runLifecycle action = lifecycle action >>= right
      workspace = EvolutionWorkspace kb identity
      livePath = directory </> "nested/kb/evolutions/e001/manifest.dhall"
      sourceFiles = tree [(path "Schema.hs","unfinished schema")]
      targetFiles = tree [(path "kb.dhall","unfinished manifest"),(path "src/Schema.hs","broken Haskell")]
      changeFiles = tree [(path "Evolution.hs","not compilable")]
      notes = tree [(path "review.md","unchanged notes")]
      initialSnapshot = WorkspaceSnapshot
        (WorkspaceManifest base "Same label λ" "Keep this explanation" Draft [IntermediateBinding "middleRoot" "Middle.Root" "Middle.metadata"])
        sourceFiles targetFiles changeFiles notes
      encodeSnapshot snapshot = right $ runPureEff . runDhallHandling . runWorkspaceStore $ encodeWorkspaceSnapshot snapshot
      writeWorkspace key snapshot = do
        encoded <- encodeSnapshot snapshot
        forM_ (files encoded) $ \(p,b) -> do
          let destination = directory </> "nested/kb/evolutions" </> key </> relativeName p
          createDirectoryIfMissing True (takeDirectory destination)
          Bytes.writeFile destination b
      expectDiagnostic :: Eff LifecycleEffects (Either [Diagnostic] a) -> IO ()
      expectDiagnostic action = runLifecycle action >>= \result -> case result of
        Left _ -> pure ()
        Right _ -> fail "Expected lifecycle diagnostic"
  emptyList <- runLifecycle (listEvolutions kb AllEvolutions) >>= right
  unless (null emptyList) (fail "Empty KB listed evolutions")
  missingId <- right (evolutionId "deadbeef")
  expectDiagnostic (resolveEvolution kb missingId)
  expectDiagnostic (markReady (EvolutionWorkspace kb missingId))
  createdMissing <- doesPathExist (directory </> "nested/kb/evolutions/deadbeef")
  unless (not createdMissing) (fail "Unknown workspace was created by lifecycle operation")
  writeWorkspace "e001" initialSnapshot
  writeWorkspace "e002" initialSnapshot
  secondId <- right (evolutionId "e002")
  let secondWorkspace = EvolutionWorkspace kb secondId
  listed <- runLifecycle (listEvolutions kb AllEvolutions) >>= right
  unless (listed == [EvolutionSummary workspace (EvolutionName "Same label λ") Draft Nothing,
      EvolutionSummary secondWorkspace (EvolutionName "Same label λ") Draft Nothing])
    (fail "Listing lost duplicate labels or changed stable order/IDs")
  hidden <- runLifecycle (listEvolutions kb ExcludeDrafts) >>= right
  unless (null hidden) (fail "Draft filter retained drafts")
  runLifecycle (markReady workspace) >>= right
  state <- runLifecycle (readEvolutionState workspace) >>= right
  unless (state == Ready) (fail "MarkReady did not change observed state")
  resolved <- runLifecycle (resolveEvolution kb identity) >>= right
  unless (resolved == workspace) (fail "Resolve returned another workspace")
  liveScope <- right (directoryScope (directory </> "nested/kb/evolutions/e001"))
  currentTree <- runEff (runFailure (runFileSystemIO scope (FS.readTree liveScope))) >>= right
  currentSnapshot <- right $ runPureEff . runDhallHandling . runWorkspaceStore $ readWorkspaceSnapshot currentTree
  unless (Workspace.matchesCapturedInputs initialSnapshot currentSnapshot)
    (fail "Ready transition invalidated captured inputs")
  let WorkspaceSnapshot _ beforeAfter targetAfter changeAfter notesAfter = currentSnapshot
  unless ((beforeAfter,targetAfter,changeAfter,notesAfter) == (sourceFiles,targetFiles,changeFiles,notes))
    (fail "State transition rewrote non-manifest files")
  filtered <- runLifecycle (listEvolutions kb ExcludeDrafts) >>= right
  unless (filtered == [EvolutionSummary workspace (EvolutionName "Same label λ") Ready Nothing])
    (fail "Draft filter used a different state derivation")
  runLifecycle (markDraft workspace) >>= right
  runLifecycle (readEvolutionState workspace) >>= right >>= \s -> unless (s == Draft) (fail "MarkDraft failed")
  let WorkspaceSnapshot (WorkspaceManifest r n e _ bindings) b t c ns = initialSnapshot
  writeWorkspace "e001" (WorkspaceSnapshot (WorkspaceManifest r n e Accepted bindings) b t c ns)
  expectDiagnostic (readEvolutionState workspace)
  runLifecycle (markReady workspace) >>= right
  validLocal <- Bytes.readFile livePath
  Bytes.writeFile livePath "True"
  expectDiagnostic (listEvolutions kb AllEvolutions)
  expectDiagnostic (markReady workspace)
  Bytes.writeFile livePath validLocal
  update <- git (compareAndSwapRef repo (LocalBranch "main") base later)
  unless (update == RefUpdated) (fail "Could not install acceptance fixture")
  acceptedList <- runLifecycle (listEvolutions kb ExcludeDrafts) >>= right
  unless (acceptedList == [EvolutionSummary workspace (EvolutionName "Example") Accepted (Just accepted)])
    (fail "Committed acceptance did not override stale local Ready/name")
  expectDiagnostic (markReady workspace)
  expectDiagnostic (markDraft workspace)
  refusedBytes <- Bytes.readFile livePath
  unless (refusedBytes == validLocal) (fail "Refused transition edited an accepted workspace")
  Bytes.writeFile livePath "malformed local manifest"
  runLifecycle (readEvolutionState workspace) >>= right >>= \s -> unless (s == Accepted) (fail "Local corruption hid acceptance")
  removeFile livePath
  resolvedArchive <- runLifecycle (resolveEvolution kb identity) >>= right
  unless (resolvedArchive == workspace) (fail "Missing live manifest hid accepted archive")
  deletedDraftHead <- git (createCommit repo (GitTree [(Subtree (path "nested/kb/evolutions/e003"),draftFiles)]) later (metadata "Shared draft"))
  _ <- git (compareAndSwapRef repo (LocalBranch "main") later deletedDraftHead)
  afterSharedDraft <- runLifecycle (listEvolutions kb AllEvolutions) >>= right
  unless (length afterSharedDraft == 2) (fail "Listing resurrected an absent local unaccepted draft")
  finalHead <- git (resolveRevision repo "HEAD") >>= right
  unless (finalHead == deletedDraftHead) (fail "Lifecycle operations advanced HEAD")
  putStrLn "Acceptance lookup identifies introductions across all parents, reverts, reacceptance and ambiguous histories."
  putStrLn "Lifecycle state/listing uses authoritative archives and state edits preserve captured inputs."

shallowFiles :: FileSystem :> es => Eff (FileSystem : es) a -> Eff es a
shallowFiles = interpret $ \_ -> \case
  FS.ListDirectory scope -> send (FS.ListDirectory scope)
  FS.ReadOptionalBytes scope path -> send (FS.ReadOptionalBytes scope path)
  FS.ReplaceBytes scope path bytes -> send (FS.ReplaceBytes scope path bytes)
  _ -> error "Lifecycle operation read source/evidence/candidates or wrote non-manifest files"

noFiles :: Eff (FileSystem : es) a -> Eff es a
noFiles = interpret $ \_ _ -> error "Acceptance lookup read the live checkout or candidate storage"

noOpening :: Eff (RootOpening : es) a -> Eff es a
noOpening = interpret $ \_ _ -> error "Acceptance lookup loaded or compiled a root"

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

rightResult :: Either e a -> IO Bool
rightResult = pure . either (const True) (const False)
