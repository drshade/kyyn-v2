{-# LANGUAGE DataKinds, TypeOperators #-}
module Kyyn.Composition (execute) where

import Effectful (Eff, runEff, (:>))
import qualified Data.Text as Text
import Kyyn.Composition.Runtime
import Kyyn.Composition.Connectors (dispatchConnectors, dispatchEvidence)
import Kyyn.Composition.Tools (dispatchTools)
import Kyyn.Composition.Queries (dispatchQueries)
import Kyyn.Composition.Outputs (dispatchOutputs)
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
import Kyyn.Guide (guideResponse)
import Kyyn.Build (guestTemplateDirectory)
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Evolution (EvolutionId, EvolutionWorkspace(..), EvolutionSummary(..), EvolutionName(..), evolutionIdName)
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Git (Repository(..), TreePath(..), revisionName)
import Kyyn.Domain.GuestApi (WorkspaceCatalogue(..), ModuleDescription(moduleName, moduleSource), ApiEntry(..), ApiOrigin(..), ApiSelection(..))
import Kyyn.Surfaces.RootBrowsing (browsingContext)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..), knowledgeBaseScope)
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore)
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Plumbing.Interpreter.BlobStorage (runBlobStorageIO)
import Kyyn.Plumbing.Capability.BlobStorage (BlobStorage)
import Kyyn.Domain.Path (DirectoryScope, directoryScope, scopedPath, relativePath)
import Kyyn.Domain.Plugin (PluginSource(..), pluginSource)
import Kyyn.Domain.Publication (InitializationTarget(..), AcceptanceResult(..), AcceptanceProblem(..))
import qualified Kyyn.Domain.Workspace as Workspace
import Kyyn.Plumbing.Interpreter.GuestCompilation (GuestBuildEnvironment)
import qualified Kyyn.Plumbing.Capability.Git as Git
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
import Kyyn.Porcelain.Capability.RootStore (rootLocation)
import Kyyn.Domain.Root (factsLocation, recipesLocation, recipeStatesLocation)
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..))
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
import Kyyn.Porcelain.Interpreter.GuestApi (runGuestApiFromCatalogue)
import Kyyn.Porcelain.Interpreter.WorkspaceApi (runWorkspaceApi)
import qualified Kyyn.Porcelain.Capability.WorkspaceApi as WorkspaceApi
import qualified Kyyn.Porcelain.Capability.GuestApi as Api
import qualified Kyyn.Surfaces.GuestApi as ApiResult
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.Result
import System.Directory (getCurrentDirectory)

type Metadata = Store.EvolutionStore ': WorkspaceStore ': Base
type Authoring = Authoring.EvolutionAuthoring ': Store.EvolutionStore ': WorkspaceStore ': RootOpening ': ToolPreparation ': PluginPreparation ': Runtime
type Evaluation = EvolutionExecution ': Authoring.EvolutionAuthoring ': Store.EvolutionStore ': WorkspaceStore ': RootOpening ': ToolPreparation ': PluginPreparation ': EvidenceStore ': BlobStorage ': DocumentPersistence ': Runtime
type Checking = RootExecution ': ToolPreparation ': PluginPreparation ': Store.EvolutionStore ': WorkspaceStore ': Runtime

runMetadata :: Host -> Eff Metadata a -> IO (Either OperationalFailure a)
runMetadata host = runBase host . runWorkspaceStore . runEvolutionStore

runAuthoring :: Host -> GuestBuildEnvironment -> Eff Authoring a -> IO (Either OperationalFailure a)
runAuthoring host settings = runRuntime host settings . runPluginPreparation . runToolPreparation . runRootOpening
  . runWorkspaceStore . runEvolutionStore . runEvolutionAuthoring

runEvaluation :: Host -> GuestBuildEnvironment -> DirectoryScope -> Eff Evaluation a -> IO (Either OperationalFailure a)
runEvaluation host settings scope = runRuntime host settings . runDocumentPersistenceIO . (runBlobStorageIO scope . runEvidenceStore scope)
  . runPluginPreparation . runToolPreparation . runRootOpening . runWorkspaceStore . runEvolutionStore . runEvolutionAuthoring . runEvolutionExecution

runChecking :: Host -> GuestBuildEnvironment -> Eff Checking a -> IO (Either OperationalFailure a)
runChecking host settings = runRuntime host settings . runWorkspaceStore . runEvolutionStore . runPluginPreparation . runToolPreparation . runRootExecution

execute :: Cli.Invocation -> IO Response
execute (Cli.Invocation _ _ Cli.Guide) = pure guideResponse
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
executeGuest selection workspace request = do
  configured <- configure selection
  case configured of
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

type Discovery = WorkspaceApi.WorkspaceApi ': Store.EvolutionStore ': WorkspaceStore ': Runtime

runDiscovery :: Host -> GuestBuildEnvironment -> Eff Discovery a -> IO (Either OperationalFailure a)
runDiscovery host settings = runRuntime host settings
  . runWorkspaceStore . runEvolutionStore . runWorkspaceApi

dispatchRootApi :: Host -> Cli.GuestCommand -> SelectedKb -> IO Response
dispatchRootApi host request (SelectedKb kb@(KnowledgeBase repository _) revision _) = withRuntime host $ \settings ->
  finish $ runDiscovery host settings $ do
    source <- case rootLocation kb of
      Left message -> pure (Left [errorDiagnostic "kb.path" message])
      Right location -> Git.readTreeExcluding repository revision (Subtree location) [factsLocation, recipesLocation, recipeStatesLocation]
    generated <- either (pure . Left) (\code -> WorkspaceApi.inspectRootApi code (apiSelection request)) source
    either (pure . refusal) (fmap (browsingContext revision Nothing) . catalogueResult request) generated

dispatchWorkspaceApi :: Host -> EvolutionWorkspace -> Cli.GuestCommand -> IO Response
dispatchWorkspaceApi host workspace request = withRuntime host $ \settings ->
  finish $ runDiscovery host settings $ do
    inspected <- WorkspaceApi.inspectWorkspaceApi workspace (apiSelection request)
    case inspected of
      Left diagnostics -> pure (refusal diagnostics)
      Right context@(WorkspaceCatalogue _ _ generated) -> case request of
        Cli.ListGuestModules -> do
          source <- Store.readWorkspace workspace
          tools <- either (pure . Left) (\(WorkspaceSnapshot _ _ code _ _) -> WorkspaceApi.inspectRootApi code ListApiModules) source
          case tools of
            Left diagnostics -> pure (refusal diagnostics)
            Right bindings -> ApiResult.workspaceResult context <$>
              catalogueResult request (map (ApiEntry GeneratedOrigin) generated ++
                [entry | entry@(ApiEntry _ selected) <- bindings, moduleName selected `notElem` map moduleName generated,
                  not (Text.pack "Kyyn.Workspace." `Text.isPrefixOf` moduleName selected)])
        _ -> ApiResult.workspaceResult context <$> catalogueResult request [ApiEntry (origin entry) entry | entry <- generated]
  where
    origin entry
      | Text.null (moduleSource entry) = SdkOrigin
      | Text.pack ".kyyn-generated/" `Text.isPrefixOf` moduleSource entry = GeneratedOrigin
      | Text.pack "plugins/" `Text.isPrefixOf` moduleSource entry = PluginOrigin
      | otherwise = KbOrigin

executeInitialization :: Host -> DirectoryScope -> IO Response
executeInitialization host scope = case guestTemplateDirectory >>= either (const Nothing) Just . directoryScope of
  Nothing -> pure (refusal [errorDiagnostic "setup.template" "This development executable has no KB template; build Kyyn with its Nix flake to initialize a KB"])
  Just directory -> do
    loaded <- runBase host (FS.readTree directory)
    either (pure . operationalFailure) (initializeWithTemplate host scope) loaded

initializeWithTemplate :: Host -> DirectoryScope -> FileTree -> IO Response
initializeWithTemplate host scope template = do
  prepared <- runBase host . runKnowledgeBaseInitialization $ Initialization.prepareKnowledgeBase scope
  case prepared of
    Left failure -> pure (operationalFailure failure)
    Right (Left diagnostics) -> pure (refusal diagnostics)
    Right (Right target@(InitializationTarget _ lookupScope _)) -> do
      metadata <- commitMetadata host (Repository lookupScope) "Initialize knowledge base\n"
      case metadata of
        Left response -> pure response
        Right commit -> withRuntime host $ \settings -> finish $
          runRuntime host settings . runPluginPreparation . runToolPreparation . runRootOpening . runRootExecution . runKnowledgeBaseInitialization $
            initializationResult <$> Initialization.initializeKnowledgeBase template target commit

dispatchRoot :: Host -> Cli.RootCommand -> SelectedKb -> IO Response
dispatchRoot host request selected@(SelectedKb kb revision _) = case request of
  Cli.RootSchema command -> dispatchSchema host command selected
  Cli.RootCollection command -> dispatchCollection host command selected
  Cli.RootFact command -> dispatchFacts host command selected
  Cli.RootQuery command -> dispatchQueries host command selected
  Cli.RootOutput command -> dispatchOutputs host command selected
  Cli.RootTool command -> dispatchTools host command selected
  Cli.RootRecipe command -> dispatchRecipes host command selected
  Cli.ShowRoot -> withRoot (inspectionCheckResult revision <$> Root.inspectRootAt kb revision)
  Cli.CheckRoot -> withRoot (checkResult ("Root at " ++ revisionName revision) <$> Root.checkRootAt kb revision)
  where
    withRoot action = withRuntime host $ \settings -> finish $
      runRuntime host settings . runPluginPreparation . runToolPreparation . runRootOpening . runRootExecution $ action
dispatchEvolution :: Host -> Cli.EvolutionCommand -> SelectedKb -> IO Response
dispatchEvolution host request (SelectedKb kb@(KnowledgeBase (Repository scope) _) revision branch) = case request of
    Cli.ListEvolutions selection -> finish $ runMetadata host $
      either refusal summariesResult <$> Store.listEvolutions kb selection
    Cli.ShowEvolution identity -> finish $ runMetadata host $
      either refusal inspectionResult <$> Store.inspectEvolution (workspace identity)
    Cli.ReadyEvolution identity -> finish $ runMetadata host $
      either refusal (const (stateResult identity Workspace.Ready)) <$> Store.markReady (workspace identity)
    Cli.DraftEvolution identity -> finish $ runMetadata host $
      either refusal (const (stateResult identity Workspace.Draft)) <$> Store.markDraft (workspace identity)
    Cli.NewEvolution name before recipe inputTypes -> withRuntime host $ \settings -> finish $ runAuthoring host settings $ do
      created <- Authoring.createEvolutionWithInputTypes kb name (maybe revision id before) (maybe Workspace.AdHoc Workspace.RecipeBased recipe) inputTypes
      pure $ case created of
        Left diagnostics -> refusal diagnostics
        Right value -> case Store.workspaceLocation value of
          Left message -> refusal [errorDiagnostic "kb.path" message]
          Right path -> workspaceResult value (maybe revision id before) (scopedPath scope path)
    Cli.CheckEvolution identity -> case knowledgeBaseScope kb of
      Left message -> pure (refusal [errorDiagnostic "kb.path" message])
      Right kbScope -> withRuntime host $ \settings -> finish $
        runEvaluation host settings kbScope . runRootExecution $
          evolutionCheckResult identity <$> checkEvolution (workspace identity)
    Cli.AcceptEvolution identity -> case branch of
      Nothing -> pure detached
      Just selected -> do
        summary <- runMetadata host (Store.readEvolutionSummary (workspace identity))
        case summary of
          Left failure -> pure (operationalFailure failure)
          Right (Left diagnostics) -> pure (refusal diagnostics)
          Right (Right (EvolutionSummary _ (EvolutionName name) state))
            | state /= Workspace.Ready -> pure (acceptanceResult (NotAccepted (NotReady state)))
            | otherwise -> do
                metadata <- commitMetadata host (Repository scope) ("Accept evolution " ++ name ++ " (" ++ evolutionIdName identity ++ ")\n")
                case metadata of
                  Left response -> pure response
                  Right commit -> withRuntime host $ \settings -> finish $
                    runChecking host settings . runRootPublication $
                      acceptanceResult <$> acceptStoredEvolution selected commit (workspace identity)
  where
    workspace = EvolutionWorkspace kb
    detached = refusal [errorDiagnostic "git.detached-head" "Check out a local branch before accepting an evolution."]
