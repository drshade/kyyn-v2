-- Disk-only lifecycle metadata, state transitions and archived reports. A real Git
-- fixture retains an old manifest while its repaired working copy is inspected.
-- The lifecycle handler has no Git or compiler effect.
{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module EvolutionMetadataTests (evolutionMetadataTests) where

import Control.Monad (unless, forM_)
import qualified Data.ByteString.Char8 as Bytes
import Effectful (Eff, IOE, (:>), runEff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret, send)
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Evolution
import Kyyn.Domain.EvolutionReport (EvolutionReport(..))
import Kyyn.Domain.Failure (OperationalFailure(..), StorageDiagnostic(..), StorageOperation(ReplaceFile))
import Kyyn.Domain.FileTree
import Kyyn.Domain.Git
import Kyyn.Domain.KnowledgeBase
import Kyyn.Domain.Path
import Kyyn.Domain.Workspace
import qualified Kyyn.Domain.Workspace as Workspace
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.Plumbing.Protocol.EvolutionRecord (encodeEvolutionRecord)
import Kyyn.Porcelain.Capability.EvolutionStore
import Kyyn.Porcelain.Capability.RootStore (RootStore)
import Kyyn.Porcelain.Capability.WorkspaceStore
import Kyyn.Porcelain.Interpreter.EvolutionStore
import Kyyn.Porcelain.Interpreter.RootStore
import Kyyn.Porcelain.Interpreter.WorkspaceStore
import System.Directory (findExecutable, createDirectoryIfMissing, removeFile, doesPathExist)
import System.FilePath ((</>), takeDirectory)
import System.IO.Temp (withSystemTempDirectory)

type LifecycleEffects = '[EvolutionStore, WorkspaceStore, RootStore, DhallHandling,
  FileSystem, FileSystem, Failure, IOE]

evolutionMetadataTests :: RootContract -> IO ()
evolutionMetadataTests contract = withSystemTempDirectory "kyyn-evolution-metadata" $ \directory -> do
  executable <- findExecutable "git" >>= maybe (fail "Git required") pure
  scope <- right (directoryScope directory)
  identity <- right (evolutionId "e001")
  secondId <- right (evolutionId "e002")
  let path = either error id . relativePath
      tree = either error id . fileTree
      kb = KnowledgeBase (Repository scope) (Subtree (path "nested/kb"))
      workspace = EvolutionWorkspace kb identity
      secondWorkspace = EvolutionWorkspace kb secondId
      livePath = directory </> "nested/kb/evolutions/e001/manifest.dhall"
      reportPath = directory </> "nested/kb/evolutions/e001/result.dhall"
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
      lifecycle :: Maybe OperationalFailure -> Eff LifecycleEffects a -> IO (Either OperationalFailure a)
      lifecycle failure action = runEff . runFailure . runFileSystemIO scope
        . shallowFiles failure . runDhallHandling . runRootStore . runWorkspaceStore . runEvolutionStore $ action
      runLifecycle :: Eff LifecycleEffects a -> IO a
      runLifecycle action = lifecycle Nothing action >>= right
      expectDiagnostic :: Eff LifecycleEffects (Either [Diagnostic] a) -> IO ()
      expectDiagnostic action = runLifecycle action >>= \case
        Left _ -> pure ()
        Right _ -> fail "Expected lifecycle diagnostic"
      writeWorkspace key snapshot = do
        encoded <- right $ runPureEff . runDhallHandling . runWorkspaceStore $ encodeWorkspaceSnapshot snapshot
        forM_ (files encoded) $ \(p,b) -> do
          let destination = directory </> "nested/kb/evolutions" </> key </> relativeName p
          createDirectoryIfMissing True (takeDirectory destination)
          Bytes.writeFile destination b
      assert label condition = unless condition (fail label)
  _ <- process ["init","-q","--ref-format=files","-b","main"]
  _ <- process ["commit","--allow-empty","-qm","Initial"]
  base <- process ["rev-parse","HEAD"] >>= right . gitRevision . Bytes.unpack . Bytes.strip
  let initialSnapshot = WorkspaceSnapshot
        (WorkspaceManifest base "Same label λ" "Keep this explanation" Draft AdHoc)
        (tree [(path "Schema.hs","unfinished schema")])
        (tree [(path "src/Schema.hs","broken Haskell")])
        (tree [(path "Evolution.hs","not compilable")])
        (tree [(path "review.md","unchanged notes")])
  emptyList <- runLifecycle (listEvolutions kb AllEvolutions) >>= right
  assert "Empty KB listed evolutions" (null emptyList)
  expectDiagnostic (resolveEvolution kb identity)
  expectDiagnostic (markReady workspace)
  exists <- doesPathExist livePath
  assert "Unknown workspace was created" (not exists)
  writeWorkspace "e001" initialSnapshot
  writeWorkspace "e002" initialSnapshot
  listed <- runLifecycle (listEvolutions kb AllEvolutions) >>= right
  assert "Listing lost duplicate labels or stable IDs"
    (listed == [EvolutionSummary workspace (EvolutionName "Same label λ") Draft,
      EvolutionSummary secondWorkspace (EvolutionName "Same label λ") Draft])
  runLifecycle (markReady workspace) >>= right
  filtered <- runLifecycle (listEvolutions kb ExcludeDrafts) >>= right
  assert "Draft filter disagrees with local state"
    (filtered == [EvolutionSummary workspace (EvolutionName "Same label λ") Ready])
  resolved <- runLifecycle (resolveEvolution kb identity) >>= right
  assert "Resolve returned another workspace" (resolved == workspace)
  liveScope <- right (directoryScope (takeDirectory livePath))
  currentTree <- runEff (runFailure (runFileSystemIO scope (FS.readTree liveScope))) >>= right
  current <- right $ runPureEff . runDhallHandling . runWorkspaceStore $ readWorkspaceSnapshot currentTree
  assert "State transition altered captured inputs" (Workspace.matchesCapturedInputs initialSnapshot current)
  let WorkspaceSnapshot _ b t c ns = initialSnapshot
      WorkspaceSnapshot _ b' t' c' ns' = current
  assert "State transition changed files" ((b,t,c,ns) == (b',t',c',ns'))
  beforeFailure <- Bytes.readFile livePath
  let failure = StorageUnavailable (StorageDiagnostic ReplaceFile livePath "Injected transition failure")
  failed <- lifecycle (Just failure) (markDraft workspace)
  afterFailure <- Bytes.readFile livePath
  assert "Failed replacement changed metadata" (failed == Left failure && beforeFailure == afterFailure)
  runLifecycle (markDraft workspace) >>= right
  writeWorkspace "e001" (WorkspaceSnapshot (WorkspaceManifest base "Accepted locally" "Reason" Accepted AdHoc) b t c ns)
  repaired <- Bytes.readFile livePath
  let old = Bytes.concat ["(",repaired,").{before, name, explanation, state}"]
      report = EvolutionReport [] []
  bytes <- right $ runPureEff $ runDhallHandling (encodeEvolutionRecord identity contract contract report)
  Bytes.writeFile reportPath bytes
  Bytes.writeFile livePath old
  _ <- process ["add","nested/kb/evolutions"]
  _ <- process ["commit","-qm","Old accepted manifest without kind"]
  beforeInspection <- process ["rev-parse","HEAD"]
  expectDiagnostic (listEvolutions kb AllEvolutions)
  Bytes.writeFile livePath repaired
  summary <- runLifecycle (readEvolutionSummary workspace) >>= right
  assert "Disk repair was ignored" (summary == EvolutionSummary workspace (EvolutionName "Accepted locally") Accepted)
  allSummaries <- runLifecycle (listEvolutions kb AllEvolutions) >>= right
  assert "Listing ignored disk repair" (take 1 allSummaries == [summary])
  inspected <- runLifecycle (inspectEvolution workspace) >>= right
  assert "Archived report requires history/cache/compiler" (inspected == (summary,Just report))
  expectDiagnostic (markReady workspace)
  expectDiagnostic (markDraft workspace)
  wrongOwner <- right $ runPureEff $ runDhallHandling (encodeEvolutionRecord secondId contract contract report)
  Bytes.writeFile reportPath wrongOwner
  expectDiagnostic (inspectEvolution workspace)
  Bytes.writeFile reportPath "True"
  expectDiagnostic (inspectEvolution workspace)
  removeFile reportPath
  missing <- runLifecycle (inspectEvolution workspace) >>= right
  assert "Absent report indistinguishable from corrupt report" (missing == (summary,Nothing))
  Bytes.writeFile livePath "True"
  expectDiagnostic (listEvolutions kb ExcludeDrafts)
  removeFile livePath
  expectDiagnostic (resolveEvolution kb identity)
  historical <- process ["show","HEAD:nested/kb/evolutions/e001/manifest.dhall"]
  afterInspection <- process ["rev-parse","HEAD"]
  assert "Metadata repair/inspection rewrote history" (historical == old && beforeInspection == afterInspection)
  putStrLn "Disk lifecycle and repaired old-manifest/report inspection passed."

shallowFiles :: (FileSystem :> es, Failure :> es)
  => Maybe OperationalFailure -> Eff (FileSystem : es) a -> Eff es a
shallowFiles failure = interpret $ \_ -> \case
  FS.ListDirectory scope -> send (FS.ListDirectory scope)
  FS.ReadOptionalBytes scope path -> send (FS.ReadOptionalBytes scope path)
  FS.ReplaceBytes scope path bytes -> maybe (send (FS.ReplaceBytes scope path bytes)) raiseFailure failure
  _ -> error "Lifecycle operation read source/evidence/candidates or wrote non-manifest files"

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
