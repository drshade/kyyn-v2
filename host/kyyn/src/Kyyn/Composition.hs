{-# LANGUAGE DataKinds, TypeOperators #-}
module Kyyn.Composition (execute) where

import Effectful (Eff, IOE, runEff, (:>))
import Data.List (isPrefixOf)
import Kyyn.Composition.Runtime
import Kyyn.Composition.Timings
import Kyyn.Composition.Connectors (dispatchConnectors, dispatchEvidence)
import Kyyn.Composition.Tools (dispatchTools)
import Kyyn.Composition.RootBrowsing (dispatchSchema, dispatchCollection, dispatchFacts)
import Kyyn.Composition.Recipes (dispatchRecipes)
import Kyyn.Composition.Secrets (executeSecrets)
import Kyyn.Composition.Taps (dispatchTaps, searchAvailablePlugins, availableGuide)
import qualified Kyyn.Porcelain.Capability.PluginDiscovery as Discovery
import Kyyn.Porcelain.Interpreter.PluginDiscovery (runPluginDiscovery)
import Kyyn.Domain.Tap (AvailablePlugin(..), CatalogueEntry(..))
import qualified Kyyn.Porcelain.Capability.PluginDocumentation as Documentation
import Kyyn.Porcelain.Interpreter.PluginDocumentation (runPluginDocumentation)
import Kyyn.Surfaces.Plugins (pluginListResult, pluginDescriptionResult, pluginGuideResult)
import Kyyn.Configuration
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Evolution (EvolutionId, EvolutionWorkspace(..), EvolutionSummary(..), EvolutionName(..), evolutionIdName)
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Git (Repository(..), TreePath(..), revisionName)
import Kyyn.Domain.GuestApi (WorkspaceCatalogue(..), ApiModule(..), ApiEntry(..), ApiOrigin(..), ApiSelection(..))
import Kyyn.Surfaces.RootBrowsing (browsingContext)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..), knowledgeBaseScope)
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore)
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Domain.Path (DirectoryScope, directoryScope, scopedPath, relativePath)
import Kyyn.Domain.Plugin (PluginSource(..), pluginSource)
import Kyyn.Domain.Publication (InitializationTarget(..))
import qualified Kyyn.Domain.Workspace as Workspace
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.MicroHs.Interpreter.GuestCompilation (runGuestCompilation)
import Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.MicroHs.Interpreter.SchemaInspection (runSchemaInspectionIO)
import Kyyn.MicroHs.Interpreter.ApiInspection (runApiInspectionIO)
import Kyyn.Plumbing.Capability.ApiInspection (ApiInspection)
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Capability.Git (Git)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExecution)
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Git (runGit)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Porcelain.Capability.Evolution (acceptStoredEvolution, checkEvolution)
import qualified Kyyn.Porcelain.Capability.Root as Root
import qualified Kyyn.Porcelain.Capability.KnowledgeBaseInitialization as Initialization
import Kyyn.Porcelain.Interpreter.KnowledgeBaseInitialization (runKnowledgeBaseInitialization)
import qualified Kyyn.Porcelain.Capability.PluginInstallation as Plugin
import Kyyn.Porcelain.Interpreter.PluginInstallation (runPluginInstallation)
import qualified Kyyn.Porcelain.Capability.EvolutionAuthoring as Authoring
import Kyyn.Porcelain.Capability.EvolutionExecution (EvolutionExecution)
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Store
import Kyyn.Porcelain.Capability.RootExecution (RootExecution)
import Kyyn.Porcelain.Capability.Tool (ToolPreparation)
import Kyyn.Porcelain.Capability.RootOpening (RootOpening)
import qualified Kyyn.Porcelain.Capability.RootPublication as Publication
import Kyyn.Porcelain.Capability.RootStore (RootStore)
import Kyyn.Porcelain.Capability.WorkspaceStore (WorkspaceStore)
import Kyyn.Porcelain.Interpreter.EvolutionAuthoring (runEvolutionAuthoring)
import Kyyn.Porcelain.Interpreter.EvolutionExecution (runEvolutionExecution)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.RootPublication (runRootPublication)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Porcelain.Interpreter.GuestApi (runGuestApi, runGuestApiFromCatalogue)
import Kyyn.Porcelain.Interpreter.WorkspaceApi (runWorkspaceApi)
import qualified Kyyn.Porcelain.Capability.WorkspaceApi as WorkspaceApi
import qualified Kyyn.Porcelain.Capability.GuestApi as Api
import qualified Kyyn.Surfaces.GuestApi as ApiResult
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.Result
import System.Directory (getCurrentDirectory, doesFileExist)
import System.FilePath ((</>))

type Metadata = Store.EvolutionStore ': WorkspaceStore ': Base
type Authoring = Authoring.EvolutionAuthoring ': Store.EvolutionStore ': WorkspaceStore ': RootOpening ': Runtime
type Evaluation = EvolutionExecution ': Authoring.EvolutionAuthoring ': Store.EvolutionStore ': WorkspaceStore ': RootOpening ': EvidenceStore ': DocumentPersistence ': Runtime
type Checking = RootExecution ': ToolPreparation ': PluginPreparation ': Store.EvolutionStore ': WorkspaceStore ': Runtime

runMetadata :: Host -> Eff Metadata a -> IO (Either OperationalFailure a)
runMetadata host = runBase host . runWorkspaceStore . runEvolutionStore

runAuthoring :: Host -> GuestToolchain -> FileTree -> Eff Authoring a -> IO (Either OperationalFailure a)
runAuthoring host toolchain sdk = runRuntime host toolchain . runRootOpening sdk
  . runWorkspaceStore . runEvolutionStore . runEvolutionAuthoring

runEvaluation :: Host -> GuestToolchain -> FileTree -> DirectoryScope -> Eff Evaluation a -> IO (Either OperationalFailure a)
runEvaluation host toolchain sdk scope = runRuntime host toolchain . runDocumentPersistenceIO . runEvidenceStore scope
  . runRootOpening sdk . runWorkspaceStore . runEvolutionStore . runEvolutionAuthoring . runEvolutionExecution sdk

runChecking :: Host -> GuestToolchain -> FileTree -> Eff Checking a -> IO (Either OperationalFailure a)
runChecking host toolchain sdk = runRuntime host toolchain . runWorkspaceStore . runEvolutionStore . runPluginPreparation sdk . runToolPreparation sdk . runRootExecution sdk

execute :: Cli.Invocation -> IO Response
execute (Cli.Invocation (Cli.Selection path _ _) _ (Cli.Secret request)) = executeSecrets path request
execute (Cli.Invocation selection _ (Cli.Guest workspace request)) = executeGuest selection workspace request
execute (Cli.Invocation selection _ command) = do
  configured <- configure selection
  case configured of
    Left response -> pure response
    Right (host,scope) -> do
      case command of
        Cli.Kb Cli.InitKb -> executeInitialization host scope
        Cli.Root request -> selectKnowledgeBase host scope >>= either pure (dispatchRoot host request)
        Cli.Evolution request -> selectKnowledgeBase host scope >>= either pure (dispatchEvolution host request)
        Cli.Plugin request -> selectKnowledgeBase host scope >>= either pure (dispatchPlugin host request)
        Cli.Tap request -> selectKnowledgeBase host scope >>= either pure (dispatchTaps host request)
        Cli.Evidence request -> selectKnowledgeBase host scope >>= either pure (dispatchEvidence host request)

executeGuest :: Cli.Selection -> Maybe EvolutionId -> Cli.GuestCommand -> IO Response
executeGuest selection@(Cli.Selection path _ runtimeOverride) workspace request = do
  runtime <- runtimeDirectory runtimeOverride
  case directoryScope runtime of
    Left message -> pure (refusal [errorDiagnostic "setup.runtime" message])
    Right catalogue -> do
      installed <- runEff . runFailure . runFileSystemIO catalogue . runDhallHandling . runGuestApi catalogue $ Api.readCatalogue
      case installed of
        Left failure -> pure (operationalFailure failure)
        Right (Left diagnostics) -> pure (refusal diagnostics)
        Right (Right modules) -> do
          hasKb <- doesFileExist (path </> "root/kb.dhall")
          let fixed = case request of
                Cli.ListGuestModules -> False
                Cli.ShowGuestModule name -> any (\(ApiModule moduleName _) -> name == moduleName) modules
                Cli.ShowGuestSymbol name -> any (\(ApiModule moduleName _) -> isPrefixOf (moduleName ++ ".") name) modules
              static = runEff (catalogueResult request (map (ApiEntry SdkOrigin) modules))
          if fixed || (not hasKb && workspace == Nothing) then static else do
            configured <- configure selection
            result <- case configured of
              Left response -> pure response
              Right (host,scope) -> case workspace of
                Nothing -> selectKnowledgeBase host scope >>= either pure (dispatchRootApi host request)
                Just identity -> do
                  discovered <- runGitIO host (Git.discoverRepository scope)
                  case discovered of
                    Left failure -> pure (operationalFailure failure)
                    Right (Left diagnostics) -> pure (refusal diagnostics)
                    Right (Right (repository,prefix)) ->
                      dispatchWorkspaceApi host (EvolutionWorkspace (KnowledgeBase repository prefix) identity) request
            pure (ApiResult.availableCatalogue (request == Cli.ListGuestModules) modules result)

dispatchPlugin :: Host -> Cli.PluginCommand -> SelectedKb -> IO Response
dispatchPlugin host (Cli.Connector command) kb = dispatchConnectors host command kb
dispatchPlugin host (Cli.SearchPlugins query) kb = searchAvailablePlugins host query kb
dispatchPlugin host (Cli.ReadPluginGuide (Cli.AvailableGuide tap name) evolution) kb = case evolution of
  Nothing -> availableGuide host tap name kb
  Just _ -> pure (refusal [errorDiagnostic "plugin.guide-selection" "Use an installed plugin name with --evolution, or omit --evolution for a tap guide"])
dispatchPlugin (Host executable environment temp _ _ _ _) (Cli.InstallAvailablePlugin identity tap name) (SelectedKb kb _ _) =
  finish $ runEff . runFailure . runProcessExecutionIO . runFileSystemIO temp
    . runGit executable environment . runDhallHandling . runRootStore . runWorkspaceStore . runEvolutionStore
    . runPluginInstallation . runPluginDiscovery $ do
      resolved <- Discovery.resolvePlugin kb tap name
      case resolved of
        Left diagnostics -> pure (refusal diagnostics)
        Right (AvailablePlugin _ _ (CatalogueEntry _ _ source path)) ->
          either refusal (pluginResult identity) <$> Plugin.installNamedPlugin (EvolutionWorkspace kb identity) name (GitPackage source (Subtree path))
dispatchPlugin (Host executable environment temp _ _ _ _) (Cli.ListPlugins evolution) (SelectedKb kb revision _) =
  finish $ runEff . runFailure . runProcessExecutionIO . runFileSystemIO temp
    . runGit executable environment . runDhallHandling . runPluginDocumentation $
      either refusal pluginListResult <$> Documentation.listPlugins
        (maybe (Documentation.AcceptedPlugins kb revision)
          (Documentation.EvolutionPlugins . EvolutionWorkspace kb) evolution)
dispatchPlugin (Host executable environment temp _ _ _ _) (Cli.ShowPlugin name evolution) (SelectedKb kb revision _) =
  finish $ runEff . runFailure . runProcessExecutionIO . runFileSystemIO temp
    . runGit executable environment . runDhallHandling . runPluginDocumentation $
      either refusal (pluginDescriptionResult evolution (Just revision)) <$> Documentation.describePlugin
        (maybe (Documentation.AcceptedPlugins kb revision)
          (Documentation.EvolutionPlugins . EvolutionWorkspace kb) evolution) name
dispatchPlugin (Host executable environment temp _ _ _ _) (Cli.ReadPluginGuide (Cli.InstalledGuide name) evolution) (SelectedKb kb revision _) =
  finish $ runEff . runFailure . runProcessExecutionIO . runFileSystemIO temp
    . runGit executable environment . runDhallHandling . runPluginDocumentation $
      either refusal (pluginGuideResult evolution (Just revision)) <$> Documentation.readPluginGuide
        (maybe (Documentation.AcceptedPlugins kb revision)
          (Documentation.EvolutionPlugins . EvolutionWorkspace kb) evolution) name
dispatchPlugin (Host executable environment temp _ _ _ _) (Cli.InstallPlugin identity source subdirectory) (SelectedKb kb _ _) = do
  cwd <- getCurrentDirectory
  let selected = do
        current <- either (Left . errorDiagnostic "plugin.source-invalid") Right (directoryScope cwd)
        path <- either (Left . errorDiagnostic "plugin.path-invalid") Right
          (maybe (Right WholeTree) (fmap Subtree . relativePath) subdirectory)
        either (Left . errorDiagnostic "plugin.source-invalid") Right (pluginSource current source path)
  case selected of
    Left diagnostic -> pure (refusal [diagnostic])
    Right value -> finish $ runEff . runFailure . runProcessExecutionIO . runFileSystemIO temp
      . runGit executable environment . runDhallHandling . runRootStore . runWorkspaceStore . runEvolutionStore . runPluginInstallation $
        either refusal (pluginResult identity) <$> Plugin.installPlugin (EvolutionWorkspace kb identity) value

guestResult :: Api.GuestApi :> es => Cli.GuestCommand -> Eff es Response
guestResult request = case request of
  Cli.ListGuestModules -> ApiResult.modulesResult <$> Api.listModules
  Cli.ShowGuestModule name -> ApiResult.moduleResult <$> Api.findModule name
  Cli.ShowGuestSymbol name -> ApiResult.symbolResult <$> Api.findSymbol name

apiSelection :: Cli.GuestCommand -> ApiSelection
apiSelection Cli.ListGuestModules = ListApiModules
apiSelection (Cli.ShowGuestModule name) = InspectApiModule name
apiSelection (Cli.ShowGuestSymbol name) = InspectApiSymbol name

catalogueResult :: Cli.GuestCommand -> [ApiEntry] -> Eff es Response
catalogueResult request entries = ApiResult.withOrigins entries <$>
  runGuestApiFromCatalogue (Right [m | ApiEntry _ m <- entries]) (guestResult request)

type Discovery = '[WorkspaceApi.WorkspaceApi, ToolPreparation, PluginPreparation, Store.EvolutionStore, WorkspaceStore, RootOpening, ApiInspection, SchemaInspection, GuestCompilation, GuestExecution, Api.GuestApi, RootStore, DhallHandling, Git, FileSystem, ProcessExecution, Failure, IOE]

runDiscovery :: Host -> GuestToolchain -> FileTree -> DirectoryScope -> Eff Discovery a -> IO (Either OperationalFailure a)
runDiscovery host@(Host _ _ _ _ cache inspection timings) toolchain sdk catalogue = runBase host . runGuestApi catalogue
  . runGuestExecution toolchain . observeExecutions timings . runGuestCompilation toolchain cache . observeCompilations timings
  . runSchemaInspectionIO toolchain inspection . runApiInspectionIO toolchain inspection . runRootOpening sdk
  . runWorkspaceStore . runEvolutionStore . runPluginPreparation sdk . runToolPreparation sdk . runWorkspaceApi sdk

dispatchRootApi :: Host -> Cli.GuestCommand -> SelectedKb -> IO Response
dispatchRootApi host@(Host _ _ _ runtime _ _ _) request (SelectedKb kb revision _) = withRuntime host $ \toolchain sdk ->
  case directoryScope runtime of
    Left message -> pure (refusal [errorDiagnostic "setup.runtime" message])
    Right catalogue -> finish $ runDiscovery host toolchain sdk catalogue $ do
      installed <- Api.readCatalogue
      source <- Root.sourceRootAt kb revision Nothing
      generated <- either (pure . Left) (\code -> WorkspaceApi.inspectRootApi code (apiSelection request)) source
      case (installed,generated) of
        (Left diagnostics,_) -> pure (refusal diagnostics)
        (_,Left diagnostics) -> pure (refusal diagnostics)
        (Right modules,Right bindings) -> browsingContext revision Nothing <$>
          catalogueResult request (map (ApiEntry SdkOrigin) modules ++ bindings)

dispatchWorkspaceApi :: Host -> EvolutionWorkspace -> Cli.GuestCommand -> IO Response
dispatchWorkspaceApi host@(Host _ _ _ runtime _ _ _) workspace request = withRuntime host $ \toolchain sdk ->
  case directoryScope runtime of
    Left message -> pure (refusal [errorDiagnostic "setup.runtime" message])
    Right catalogue -> finish $ runDiscovery host toolchain sdk catalogue $ do
      installed <- Api.readCatalogue
      case installed of
        Left diagnostics -> pure (refusal diagnostics)
        Right modules -> do
          inspected <- WorkspaceApi.inspectWorkspaceApi workspace
          case inspected of
            Left diagnostics -> pure (refusal diagnostics)
            Right context@(WorkspaceCatalogue _ revision generated) -> do
              let EvolutionWorkspace kb identity = workspace
              source <- Root.sourceRootAt kb revision (Just identity)
              tools <- either (pure . Left) (\code -> WorkspaceApi.inspectRootApi code (apiSelection request)) source
              case tools of
                Left diagnostics -> pure (refusal diagnostics)
                Right bindings -> ApiResult.workspaceResult context <$>
                  catalogueResult request (map (ApiEntry SdkOrigin) modules ++ map (ApiEntry GeneratedOrigin) generated ++ bindings)

executeInitialization :: Host -> DirectoryScope -> IO Response
executeInitialization host scope = do
  prepared <- runBase host . runKnowledgeBaseInitialization $ Initialization.prepareKnowledgeBase scope
  case prepared of
    Left failure -> pure (operationalFailure failure)
    Right (Left diagnostics) -> pure (refusal diagnostics)
    Right (Right target@(InitializationTarget _ lookupScope _)) -> do
      metadata <- commitMetadata host (Repository lookupScope) "Initialize knowledge base\n"
      case metadata of
        Left response -> pure response
        Right commit -> withRuntime host $ \toolchain sdk -> finish $
          runRuntime host toolchain . runRootOpening sdk . runPluginPreparation sdk . runToolPreparation sdk . runRootExecution sdk . runKnowledgeBaseInitialization $
            initializationResult <$> Initialization.initializeKnowledgeBase target commit

dispatchRoot :: Host -> Cli.RootCommand -> SelectedKb -> IO Response
dispatchRoot host request selected@(SelectedKb kb revision _) = case request of
  Cli.RootSchema command -> dispatchSchema host command selected
  Cli.RootCollection command -> dispatchCollection host command selected
  Cli.RootFact command -> dispatchFacts host command selected
  Cli.RootTool command -> dispatchTools host command selected
  Cli.RootRecipe command -> dispatchRecipes host command selected
  Cli.ShowRoot -> withRoot (inspectionCheckResult revision <$> Root.inspectRootAt kb revision)
  Cli.CheckRoot -> withRoot (checkResult ("Root at " ++ revisionName revision) <$> Root.checkRootAt kb revision)
  where
    withRoot action = withRuntime host $ \toolchain sdk -> finish $
      runRuntime host toolchain . runRootOpening sdk . runPluginPreparation sdk . runToolPreparation sdk . runRootExecution sdk $ action
dispatchEvolution :: Host -> Cli.EvolutionCommand -> SelectedKb -> IO Response
dispatchEvolution host request (SelectedKb kb@(KnowledgeBase (Repository scope) _) revision branch) = case request of
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
    Cli.CheckEvolution identity -> case knowledgeBaseScope kb of
      Left message -> pure (refusal [errorDiagnostic "kb.path" message])
      Right kbScope -> withRuntime host $ \toolchain sdk -> finish $
        runEvaluation host toolchain sdk kbScope . runPluginPreparation sdk . runToolPreparation sdk . runRootExecution sdk $
          evolutionCheckResult identity <$> checkEvolution (workspace identity)
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
                metadata <- commitMetadata host (Repository scope) ("Accept evolution " ++ name ++ " (" ++ evolutionIdName identity ++ ")\n")
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
