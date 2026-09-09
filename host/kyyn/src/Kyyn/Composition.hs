{-# LANGUAGE DataKinds, TypeOperators #-}
module Kyyn.Composition (execute) where

import Effectful (Eff, IOE, runEff)
import Kyyn.Configuration
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Evolution (EvolutionWorkspace(..), EvolutionSummary(..), EvolutionName(..), evolutionIdName)
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Git (Repository(..), revisionName)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (directoryScope, scopedPath)
import qualified Kyyn.Domain.Workspace as Workspace
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.MicroHs.Interpreter.GuestCompilation (runGuestCompilation)
import Kyyn.MicroHs.Interpreter.SchemaInspection (runSchemaInspectionIO)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem, readTree)
import Kyyn.Plumbing.Capability.Git (Git)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExecution)
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Git (runGit)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Porcelain.Capability.Evolution (acceptStoredEvolution, evaluateWorkspace, checkWorkspace)
import qualified Kyyn.Porcelain.Capability.Root as Root
import qualified Kyyn.Porcelain.Capability.EvolutionAuthoring as Authoring
import Kyyn.Porcelain.Capability.EvolutionExecution (EvolutionExecution)
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Store
import Kyyn.Porcelain.Capability.RootExecution (RootExecution)
import Kyyn.Porcelain.Capability.RootOpening (RootOpening)
import qualified Kyyn.Porcelain.Capability.RootPublication as Publication
import Kyyn.Porcelain.Capability.RootStore (RootStore)
import Kyyn.Porcelain.Capability.WorkspaceStore (WorkspaceStore)
import Kyyn.Porcelain.Interpreter.EvolutionAuthoring (runEvolutionAuthoring)
import Kyyn.Porcelain.Interpreter.EvolutionExecution (runEvolutionExecution)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.RootPublication (runRootPublication)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.Result
import System.FilePath ((</>))

type Base = '[RootStore, DhallHandling, Git, FileSystem, ProcessExecution, Failure, IOE]
type Metadata = Store.EvolutionStore ': WorkspaceStore ': Base
type Runtime = SchemaInspection ': GuestCompilation ': Base
type Authoring = Authoring.EvolutionAuthoring ': Store.EvolutionStore ': WorkspaceStore ': RootOpening ': Runtime
type Evaluation = EvolutionExecution ': Authoring
type Checking = RootExecution ': Store.EvolutionStore ': WorkspaceStore ': Runtime

runBase :: Host -> Eff Base a -> IO (Either OperationalFailure a)
runBase (Host executable temp _) = runEff . runFailure . runProcessExecutionIO
  . runFileSystemIO temp . runGit executable . runDhallHandling . runRootStore

runMetadata :: Host -> Eff Metadata a -> IO (Either OperationalFailure a)
runMetadata host = runBase host . runWorkspaceStore . runEvolutionStore

runRuntime :: Host -> GuestToolchain -> Eff Runtime a -> IO (Either OperationalFailure a)
runRuntime host toolchain = runBase host . runGuestCompilation toolchain . runSchemaInspectionIO toolchain

runAuthoring :: Host -> GuestToolchain -> FileTree -> Eff Authoring a -> IO (Either OperationalFailure a)
runAuthoring host toolchain sdk = runRuntime host toolchain . runRootOpening sdk
  . runWorkspaceStore . runEvolutionStore . runEvolutionAuthoring

runEvaluation :: Host -> GuestToolchain -> FileTree -> Eff Evaluation a -> IO (Either OperationalFailure a)
runEvaluation host toolchain sdk = runAuthoring host toolchain sdk . runEvolutionExecution sdk

runChecking :: Host -> GuestToolchain -> FileTree -> Eff Checking a -> IO (Either OperationalFailure a)
runChecking host toolchain sdk = runRuntime host toolchain . runWorkspaceStore . runEvolutionStore . runRootExecution sdk

execute :: Cli.Invocation -> IO Response
execute (Cli.Invocation selection _ command) = do
  configured <- configure selection
  case configured of
    Left response -> pure response
    Right (host,scope) -> do
      selected <- selectKnowledgeBase host scope
      either pure (dispatch host command) selected

dispatch :: Host -> Cli.Command -> SelectedKb -> IO Response
dispatch host command (SelectedKb kb@(KnowledgeBase (Repository scope) _) revision branch) = case command of
  Cli.Root request -> withRuntime host $ \toolchain sdk -> finish $
    runRuntime host toolchain . runRootOpening sdk . runRootExecution sdk $ case request of
      Cli.ShowRoot -> inspectionCheckResult revision <$> Root.inspectRootAt kb revision
      Cli.CheckRoot -> checkResult ("Root at " ++ revisionName revision) <$> Root.checkRootAt kb revision
  Cli.Evolution request -> case request of
    Cli.ListEvolutions selection -> finish $ runMetadata host $
      either refusal summariesResult <$> Store.listEvolutions kb selection
    Cli.ShowEvolution identity -> finish $ runMetadata host $
      either refusal (inspectionResult revision) <$> Store.inspectEvolution (workspace identity) revision
    Cli.ReadyEvolution identity -> finish $ runMetadata host $
      either refusal (const (stateResult identity Workspace.Ready)) <$> Store.markReady (workspace identity)
    Cli.DraftEvolution identity -> finish $ runMetadata host $
      either refusal (const (stateResult identity Workspace.Draft)) <$> Store.markDraft (workspace identity)
    Cli.NewEvolution name before -> withRuntime host $ \toolchain sdk -> finish $ runAuthoring host toolchain sdk $ do
      created <- Authoring.createEvolution kb name (maybe revision id before)
      pure $ case created of
        Left diagnostics -> refusal diagnostics
        Right value -> case Store.workspaceLocation value of
          Left message -> refusal [errorDiagnostic "kb.path" message]
          Right path -> workspaceResult value (maybe revision id before) (scopedPath scope path)
    Cli.EvaluateEvolution identity -> withRuntime host $ \toolchain sdk -> finish $
      runEvaluation host toolchain sdk (either previewRefusal candidateResult <$> evaluateWorkspace (workspace identity))
    Cli.CheckEvolution identity -> withRuntime host $ \toolchain sdk -> finish $
      runChecking host toolchain sdk (checkResult ("Candidate " ++ evolutionIdName identity) <$> checkWorkspace (workspace identity))
    Cli.AcceptEvolution identity -> case branch of
      Nothing -> pure detached
      Just selected -> do
        accepted <- runMetadata host . runRootPublication $
          Publication.findAcceptanceOnBranch selected (workspace identity)
        case accepted of
          Left failure -> pure (operationalFailure failure)
          Right (Left diagnostics) -> pure (refusal diagnostics)
          Right (Right (Just acceptedRevision)) -> pure (acceptanceResult (Publication.alreadyAccepted acceptedRevision))
          Right (Right Nothing) -> do
            summary <- runMetadata host (Store.readEvolutionSummary (workspace identity) revision)
            case summary of
              Left failure -> pure (operationalFailure failure)
              Right (Left diagnostics) -> pure (refusal diagnostics)
              Right (Right (EvolutionSummary _ (EvolutionName name) _ _)) -> do
                metadata <- commitMetadata ("Accept evolution " ++ name ++ " (" ++ evolutionIdName identity ++ ")\n")
                case metadata of
                  Left response -> pure response
                  Right commit -> withRuntime host $ \toolchain sdk -> finish $
                    runChecking host toolchain sdk . runRootPublication $
                      acceptanceResult <$> acceptStoredEvolution selected commit (workspace identity)
    Cli.RecoverEvolution identity -> case branch of
      Nothing -> pure detached
      Just selected -> finish $ runMetadata host . runRootPublication $
        either refusal recoveryResult <$> Publication.recoverAcceptedEvolution selected (workspace identity)
  where
    workspace = EvolutionWorkspace kb
    detached = refusal [errorDiagnostic "git.detached-head" "Check out a local branch before accepting or recovering an evolution."]

finish :: IO (Either OperationalFailure Response) -> IO Response
finish action = either operationalFailure id <$> action

withRuntime :: Host -> (GuestToolchain -> FileTree -> IO Response) -> IO Response
withRuntime (Host _ temp runtime) action = case (directoryScope (runtime </> "microhs"), directoryScope (runtime </> "sdk")) of
  (Right toolchain,Right sdkScope) -> do
    loaded <- runEff . runFailure . runFileSystemIO temp $ readTree sdkScope
    case loaded of
      Left failure -> pure (operationalFailure failure)
      Right sdk -> action (GuestToolchain toolchain) sdk
  _ -> pure (refusal [errorDiagnostic "setup.runtime" "Runtime must resolve to an absolute directory"])
