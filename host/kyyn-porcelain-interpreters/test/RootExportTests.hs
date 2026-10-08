{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module RootExportTests (rootExportTests) where

import GuestFixture (noRecipePreparation)

import Kyyn.Porcelain.Protocol.RecipePersistence (encodeRecipes)
import Control.Monad (unless)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Data.List (partition, isPrefixOf)
import Effectful (Eff, IOE, runEff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Contract (CheckedContract, rootSchema)
import Kyyn.Domain.FileTree
import Kyyn.Domain.Git
import Kyyn.Domain.Path
import Kyyn.Domain.Root
import Kyyn.Domain.Evolution
import Kyyn.Domain.EvolutionReport (EvolutionReport(..), StepReport(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Workspace
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Plumbing.Capability.Git
import Kyyn.Plumbing.Capability.Failure (Failure)
import qualified Kyyn.Plumbing.Capability.SchemaInspection as Schema
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Protocol.EvolutionRecord (decodeEvolutionRecord)
import Kyyn.Plumbing.Interpreter.Git
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.Porcelain.Capability.RootExecution
import Kyyn.Porcelain.RootExecution.Types (PreparedRoot(..))
import Kyyn.Porcelain.Capability.RootOpening (openCapturedRoot)
import Kyyn.Porcelain.Capability.EvolutionStore (exportAcceptedWorkspace, findAcceptance)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.Capability.Validation (checkRoot)
import Kyyn.Porcelain.Interpreter.RootStore
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Validated (validatedValue)
import System.Directory (createDirectoryIfMissing, findExecutable)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

rootExportTests :: Root -> IO ()
rootExportTests original@(Root contract facts code _) = withSystemTempDirectory "kyyn-root-export" $ \directory -> do
  executable <- findExecutable "git" >>= maybe (fail "Git required for root export integration") pure
  scope <- either fail pure (directoryScope directory)
  let path = either error id . relativePath
      tree = either error id . fileTree
      repo = Repository scope
      manifest = "{ schemaType = \"Example.Root\", schemaMetadata = \"Example.schemaMetadata\", validator = \"Example.validate\", queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }"
      completeCode = tree ([(p,if relativeName p == "kb.dhall" then manifest else b) | (p,b) <- files code] ++ [(path "plugins/config/example.dhall","{ enabled = True }"),
        (path "assets/template.bin",Bytes.pack [0..255])])
      root = Root contract facts completeCode []
      storage action = runPureEff (runDhallHandling (runRootStore action))
      outcome = runPureEff . checkingMock root . runDhallHandling . runRootStore $ checkRoot root
  checked <- case outcome of
    Passed value _ -> pure value
    _ -> fail (show outcome)
  exported <- either (fail . show) pure (storage (exportRootFiles checked))
  recipeBytes <- either (fail . show) pure (runPureEff (runDhallHandling (encodeRecipes [])))
  unless (exported == tree ((recipesLocation,recipeBytes) : files facts ++ files completeCode) && validatedValue checked == root)
    (fail "Export substituted or rerendered the validated root")
  let process args = do
        result <- runEff . runFailure . runProcessExecutionIO $ Process.withProcess
          (Process.ProcessSpec executable args directory [("PATH",""),("LC_ALL","C"),("GIT_CONFIG_NOSYSTEM","1")]) $ do
            Process.closeStdin
            bytes <- Process.collectStdout
            status <- Process.awaitExit
            pure (bytes,status)
        case result of Right (bytes,Process.ProcessExit 0 _) -> pure bytes; _ -> fail (show result)
      command args = () <$ process args
      git :: Eff [Git, Process.ProcessExecution, Failure, IOE] a -> IO a
      git action = runEff (runFailure (runProcessExecutionIO (runGit executable [] action))) >>= either (fail . show) pure
      readGit :: Eff [Git, Process.ProcessExecution, Failure, IOE] (Either [Diagnostic] a) -> IO a
      readGit action = git action >>= either (fail . show) pure
  command ["init","-q","--ref-format=files","-b","main"]
  createDirectoryIfMissing True (directory </> "kb/root")
  createDirectoryIfMissing True (directory </> "kb/evolutions/e001")
  Bytes.writeFile (directory </> "kb/evolutions/e001/obsolete") "remove with complete archive replacement"
  Bytes.writeFile (directory </> "kb/root/obsolete") "delete on replacement"
  Bytes.writeFile (directory </> "outside") "committed outside"
  command ["add","kb","outside"]
  command ["-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","base"]
  parent <- readGit (resolveRevision repo "HEAD")
  workspaceId <- either fail pure (evolutionId "e001")
  let kb = KnowledgeBase repo (Subtree (path "kb"))
      beforeSource = tree [(path "Schema.hs","captured before source")]
      changeSource = tree [(path "Evolution.hs","captured change source")]
      captured = WorkspaceSnapshot (WorkspaceManifest parent "Export" "Fixed proposal" Ready AdHoc) beforeSource completeCode changeSource (tree [])
      report = EvolutionReport [] [StepReport (Rationale "Retain this explanation" []) []]
      candidate = Candidate (EvolutionContext kb workspaceId (Before parent contract) captured) report checked
  createDirectoryIfMissing True (directory </> "kb/evolutions/e001/notes")
  Bytes.writeFile (directory </> "kb/evolutions/e001/notes/review.md") "later review note"
  archiveResult <- runEff . runFailure . runFileSystemIO scope . noGitExport
    . runDhallHandling . runRootStore . runWorkspaceStore . runEvolutionStore $
      exportAcceptedWorkspace candidate
  archiveReplacement@(archivePrefix,archiveFiles) <- either (fail . show) pure archiveResult >>= either (fail . show) pure
  unless (archivePrefix == Subtree (path "kb/evolutions/e001")) (fail "Archive export returned wrong replacement prefix")
  Bytes.writeFile (directory </> "outside") "staged outside"
  command ["add","outside"]
  Bytes.writeFile (directory </> "outside") "unstaged outside"
  indexBefore <- Bytes.readFile (directory </> ".git/index")
  reexported <- either (fail . show) pure (storage (exportRootFiles checked))
  unless (reexported == exported) (fail "Export read live files after validation")
  let metadata = CommitMetadata (CommitIdentity "Author" "author@example.invalid" "1700000000 +0000")
        (CommitIdentity "Committer" "committer@example.invalid" "1700000001 +0000") "Export exact checked root"
  revision <- git (createCommit repo (GitTree [(Subtree (path "kb/root"),exported),archiveReplacement]) (Just parent) metadata)
  beforePublication <- readGit (resolveRevision repo "HEAD")
  unless (beforePublication == parent) (fail "Constructing exported-root commit moved head")
  updated <- git (compareAndSwapRef repo (LocalBranch "main") (Just parent) revision)
  unless (updated == RefUpdated) (fail "Expected-parent publication failed")
  reopened <- readGit (readTreeAt repo revision (Subtree (path "kb/root")))
  unless (reopened == exported) (fail "Committed files differ from the validated root export")
  reopenedArchive <- readGit (readTreeAt repo revision archivePrefix)
  unless (reopenedArchive == archiveFiles) (fail "Committed archive differed from exported capture/report/notes")
  recordBytes <- maybe (fail "Committed archive lacks result.dhall") pure (lookup (path "result.dhall") (files reopenedArchive))
  decodedRecord <- either fail pure (runPureEff (runDhallHandling (decodeEvolutionRecord recordBytes))) >>= either (fail . show) pure
  unless (decodedRecord == (workspaceId,contract,contract,report)) (fail "Committed record changed contracts/report")
  accepted <- runEff . runFailure . runProcessExecutionIO . runGit executable [] . runFileSystemIO scope
    . runDhallHandling . runRootStore . runWorkspaceStore . runEvolutionStore $
      findAcceptance kb workspaceId revision
  unless (accepted == Right (Right (Just revision))) (fail "Combined commit did not introduce its Accepted archive")
  opened <- runEff . runFailure . runProcessExecutionIO . runGit executable [] . schemaMock (rootSchema contract)
    . runDhallHandling . runRootStore . noRecipePreparation . runRootOpening (tree []) $ openCapturedRoot reopened
  unless (opened == Right (Right (validatedValue checked))) (fail "Reopened Root differs from the validated input")
  contents <- process ["show",revisionName revision ++ ":outside"]
  unless (contents == "committed outside") (fail "Commit included unrelated staged or working changes")
  parents <- process ["show","-s","--format=%P",revisionName revision]
  unless (Char8.strip parents == Char8.pack (revisionName parent)) (fail "Exported commit has a different parent")
  currentIndex <- Bytes.readFile (directory </> ".git/index")
  liveOutside <- Bytes.readFile (directory </> "outside")
  unless (currentIndex == indexBefore && liveOutside == "unstaged outside")
    (fail "Export/commit/ref primitives modified the checkout")
  let (factEntries,codeEntries) = partition (\(p,_) -> "facts/" `isPrefixOf` relativeName p) (files reopened)
  reopenedValue <- either (fail . show) pure (storage (loadRootValueForChecking (Root contract (tree factEntries) (tree codeEntries) [])))
  originalValue <- either (fail . show) pure (storage (loadRootValueForChecking original))
  unless (reopenedValue == originalValue) (fail "Reopened committed facts changed")
  putStrLn "Validated root export composes with real Git commit/CAS: exact files, deletion, parent and unrelated checkout preservation passed."

noGitExport :: Eff (Git : es) a -> Eff es a
noGitExport = interpret $ \_ _ -> error "Archive export used Git"

checkingMock :: Root -> Eff (RootExecution : es) a -> Eff es a
checkingMock expected = interpret $ \_ -> \case
  PrepareRoot root -> same root >> pure (Right (PreparedRoot root "validator" (error "Unexpected bytecode use") [] [] []))
  ValidateRoot root -> same (preparedRoot root) >> pure (Right (ValidationReport []))
  ExecuteQuery _ _ _ -> error "Unexpected query in export fixture"
  where
    same :: Root -> Eff xs ()
    same root = unless (root == expected) (error "Validation switched roots")

schemaMock :: CheckedContract -> Eff (Schema.SchemaInspection : es) a -> Eff es a
schemaMock contract = interpret $ \_ -> \case
  Schema.InspectImports {} -> error "Unexpected import inspection"
  Schema.InspectType {} -> error "Unexpected plain type inspection"
  Schema.InspectRecipeFunction {} -> error "Unexpected recipe signature inspection"
  Schema.InspectRecipeExports {} -> error "Unexpected recipe exports inspection"
  Schema.InspectPluginFunction {} -> error "Unexpected plugin signature inspection"
  Schema.InspectSchema source -> do
    unless (Schema.selectedType source == "Example.Root") (error "Reopening selected a different schema")
    pure (Right (Schema.InspectedSchema contract []))
