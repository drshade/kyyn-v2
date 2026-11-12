{-# LANGUAGE GADTs, LambdaCase, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Porcelain.Interpreter.Inspection (runInspection) where

import Control.Monad (forM)
import Kyyn.Domain.Evidence
import Kyyn.Domain.EvidenceIndex (EvidenceSelection(..), PayloadLocation(..), indexedEvidence)
import Kyyn.Types.Evidence (EvidenceRef(..))
import qualified Kyyn.Porcelain.Capability.EvidenceStore as EvidenceStore
import qualified Kyyn.Porcelain.Capability.EvidenceInspection as EvidenceRead
import qualified Kyyn.Porcelain.Capability.PluginPreparation as Plugins
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (nub, sort, isSuffixOf, stripPrefix)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Contract (contractId, contractShape)
import qualified Kyyn.Domain.Output
import Kyyn.Domain.Query (QueryDefinition(..), QueryDescriptor(..), QueryResult(..))
import Kyyn.Domain.Tool (ToolDefinition(..), ToolDescriptor(..))
import Kyyn.Domain.Plugin (ConnectorName(..), PluginName, PluginOrigin, pluginName, MethodName(..))
import Kyyn.Plumbing.Protocol.Plugin (decodeOrigin)
import Kyyn.Domain.Path (relativeName)
import Kyyn.Domain.DataType (definingModule)
import Kyyn.Domain.Recipe (RecipeDefinition(..), recipeDefinition, DescriptionFormat(Mermaid))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Domain.Evolution
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Git (TreePath(..))
import Kyyn.Domain.Inspection
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Root (Root(..), RootDefinition(..), SourceRoot(..), isRootMaterial)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionState(..))
import qualified Kyyn.Plumbing.Capability.Git as Git
import qualified Kyyn.Plumbing.Capability.DhallHandling as Dhall
import qualified Kyyn.Porcelain.Capability.RootExecution as Query
import qualified Kyyn.Porcelain.Capability.Tool as Tool
import qualified Kyyn.Porcelain.Capability.RecipeInspection as Recipe
import Kyyn.Porcelain.Capability.Inspection
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Store
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadRootAt)
import Kyyn.Porcelain.Capability.RootStore (RootStore, rootLocation, loadRootValueForChecking, readRootDefinition)

runInspection :: (RootOpening :> es, RootStore :> es, Store.EvolutionStore :> es, Git.Git :> es,
  Plugins.PluginPreparation :> es, EvidenceStore.EvidenceStore :> es, EvidenceRead.EvidenceInspection :> es,
  Query.RootExecution :> es, Tool.ToolPreparation :> es, Recipe.RecipeInspection :> es, Dhall.DhallHandling :> es)
  => Eff (Inspection : es) a -> Eff es a
runInspection = interpret $ \_ -> \case
  InspectConfiguration (SnapshotInspection _ _ (Root _ _ code _) _ _) -> runExceptT $ do
    origins <- inspectOrigins code
    pure (ConfigurationInspection origins)
  InspectConnectors (SnapshotInspection _ _ (Root _ _ code _) _ _) -> runExceptT $ do
    plugins <- ExceptT (Plugins.preparePlugins code)
    forM [(package,name,binding,connector,payload,config) |
      Plugins.PreparedPlugin package instances <- plugins,
      Plugins.ConfiguredConnector name binding connector@Plugins.PreparedConnector{Plugins.payloadContract = payload} config <- instances] $
      \(Plugins.PreparedPackage plugin identity _,name@(ConnectorName instanceName),binding,connector,payload,config) -> do
        captured <- ExceptT (Right <$> EvidenceStore.openCurrentEvidence
          (EvidenceSelection (ConnectorInstanceRef plugin instanceName) connector.connectorType identity))
        let current = case captured of
              Left problem -> Left [evidenceProblemDiagnostic problem]
              Right Nothing -> Left [evidenceProblemDiagnostic NotFetched]
              Right (Just index) -> Right index
        pure (ConnectorInspection plugin identity name binding connector.connectorType
          connector.configContract config payload current)
  InspectEvidenceItem connector key -> runExceptT $ do
    index <- ExceptT (pure connector.capture)
    found <- ExceptT (fmap (either (Left . pure . evidenceProblemDiagnostic) Right) (EvidenceStore.readCapturedEvidence index key))
    item <- maybe (throwE [errorDiagnostic "inspection.unknown" "No current evidence with this ID"]) pure found
    let refs = case indexedEvidence index key of
          Just (Evidence _ _ (Available (PayloadLocation _ _ blobs))) -> blobs
          _ -> []
    pure (EvidenceItemInspection key item refs)
  InspectEvidenceReferences kb revision references -> do
    groups <- forM (nub [(ref.producer,ref.instanceName) | ref <- references]) $ \(producer,instanceName) -> do
      current <- runExceptT $ do
        plugin <- checked (pluginName (Text.unpack producer))
        selection <- ExceptT (EvidenceRead.selectEvidence kb revision plugin (ConnectorName (Text.unpack instanceName)))
        ExceptT (EvidenceRead.currentEvidence selection)
      pure ((producer,instanceName),current)
    pure [(ref,do
      EvidenceCapture _ _ items _ <- maybe (Left [errorDiagnostic "evidence.not-found" "Not in local evidence"]) id
        (lookup (ref.producer,ref.instanceName) groups)
      if any (\(EvidenceId key,_,_) -> key == ref.source) items then Right ()
      else Left [errorDiagnostic "evidence.not-found" "Not in local evidence"]) | ref <- references]
  InspectSnapshot kb@(KnowledgeBase repository _) revision selected -> runExceptT $ do
    (base,root@(Root _ _ code _)) <- case selected of
      Nothing -> do
        path <- checked (rootLocation kb)
        (revision,) <$> ExceptT (loadRootAt repository revision (Subtree path))
      Just identity -> do
        let workspace = EvolutionWorkspace kb identity
        state <- ExceptT (Store.readEvolutionState workspace)
        case state of
          Accepted -> throwE [errorDiagnostic "inspection.accepted" "This evolution is accepted; use the accepted KB link"]
          _ -> pure ()
        candidate <- ExceptT (Store.loadCheckedCandidate workspace)
        case candidate of
          Nothing -> throwE [errorDiagnostic "evolution.no-candidate" "No successfully checked candidate is available"]
          Just (Candidate (EvolutionContext _ _ before _) _ root) -> pure (beforeRevision before,root)
    CheckedValue _ value <- ExceptT (loadRootValueForChecking root)
    definition <- ExceptT (readRootDefinition code)
    pure (SnapshotInspection base selected root value definition)
  InspectDeclaration (SnapshotInspection _ _ root@(Root contract _ code recipes) _
      definition@(RootDefinition _ _ _ queries tools _ _)) request -> runExceptT $ do
    let source implementation = do
          let name = definingModule implementation
              suffixes = ["src/" ++ map (\c -> if c == '.' then '/' else c) name ++ extension | extension <- [".hs",".lhs"]]
              candidates = [bytes | (path,bytes) <- files code,
                any (\suffix -> relativeName path == suffix || ("/" ++ suffix) `isSuffixOf` relativeName path) suffixes]
          body <- case candidates of
            [] -> pure Nothing
            [bytes] -> Just <$> checked (either (Left . show) Right (Text.decodeUtf8' bytes))
            _ -> throwE [errorDiagnostic "inspection.source" "Implementation module has multiple captured source files"]
          pure (ImplementationSource (Text.pack name) body)
        unknown kind name = throwE [errorDiagnostic "inspection.unknown" ("Unknown " ++ kind ++ ": " ++ name)]
    case request of
      PluginRequest name -> do
        selected <- checked (pluginName (Text.unpack name))
        origins <- inspectOrigins code
        origin <- maybe (unknown "plugin" (Text.unpack name)) pure (lookup selected origins)
        plugins <- ExceptT (Plugins.preparePlugins code)
        Plugins.PreparedPlugin (Plugins.PreparedPackage identity fingerprint connectors) instances <- ExceptT (pure (Plugins.selectedPlugin selected plugins))
        let describe connector =
              let configured = [(n,b,v) | Plugins.ConfiguredConnector n b c v <- instances, c.connectorType == connector.connectorType]
                  config = ("configuration",connector.configContract)
              in case connector of
                Plugins.PreparedConnector { Plugins.payloadContract = payload, Plugins.fetchOptionsContract = options,
                  Plugins.reportContract = report, Plugins.methods = methods } ->
                  ConnectorDeclarationInspection connector.connectorType False
                    ([config,("payload",payload)] ++ maybe [] (pure . ("options",)) options ++ maybe [] (pure . ("report",)) report ++
                     concat [[("method:" ++ method ++ ":input",input),("method:" ++ method ++ ":result",output)] |
                       Plugins.PreparedMethod (MethodName method) _ input output _ <- methods])
                    [(method,description) | Plugins.PreparedMethod method description _ _ _ <- methods] configured
                Plugins.PreparedSinkConnector { Plugins.sinkInputContract = input, Plugins.sinkOptionsContract = options,
                  Plugins.sinkResultContract = output } ->
                  ConnectorDeclarationInspection connector.connectorType True
                    [config,("input",input),("options",options),("result",output)] [] configured
        pure (PluginInspection identity fingerprint origin (map describe connectors))
      OutputRequest name -> do
        prepared <- ExceptT (Query.prepareRoot root)
        case [ (output,descriptor) | Query.PreparedOutput output@(Kyyn.Domain.Output.OutputDefinition actual _ _ _) descriptor _ <- Query.preparedOutputs prepared, actual == name] of
          [(output,descriptor)] -> pure (OutputInspection output descriptor)
          _ -> unknown "output" name
      QueryRequest name supplied -> do
        declaration@(QueryDefinition _ _ implementation _ _ _ _) <- case
          [query | query@(QueryDefinition actual _ _ _ _ _ _) <- queries, actual == name] of
            [query] -> pure query
            _ -> unknown "query" name
        prepared <- ExceptT (Query.prepareRoot root)
        descriptor@(QueryDescriptor _ _ input _) <- ExceptT (pure (Query.selectQuery prepared name))
        result <- traverse (\text -> do
          args <- ExceptT (Dhall.decodeValue (contractShape input) text)
          QueryResult (CheckedValue _ value) _ <- ExceptT
            (Query.queryRoot prepared descriptor (CheckedValue (contractId input) args))
          pure value) supplied
        QueryInspection declaration descriptor <$> source implementation <*> pure result
      ToolRequest name -> do
        declaration@(ToolDefinition _ _ _ _ implementation) <- case
          [tool | tool@(ToolDefinition (MethodName actual) _ _ _ _) <- tools, actual == name] of
            [tool] -> pure tool
            _ -> unknown "tool" name
        prepared <- ExceptT (Tool.prepareTools code)
        (descriptor,model) <- case [(descriptor,model) | Tool.PreparedTool descriptor@(ToolDescriptor (MethodName actual) _ _ _) _ _ model <- prepared, actual == name] of
          [value] -> pure value
          _ -> unknown "tool" name
        ToolInspection declaration descriptor model <$> source implementation
      RecipeRequest name -> do
        recipe <- case [value | Fact (FactId actual) value <- recipes, actual == name] of
          [value] -> pure value
          _ -> unknown "recipe" (Text.unpack name)
        let method = recipeDefinition recipe
        flow <- case method of
          OpenRecipe _ _ -> pure Nothing
          ClosedRecipe entry -> Just <$> ExceptT (Recipe.describeRecipe (SourceRoot contract code definition []) entry Mermaid)
        pure (RecipeInspection name recipe flow)
  InspectEvolutionSource workspace@(EvolutionWorkspace kb@(KnowledgeBase repository _) _) -> runExceptT $ do
    live@(WorkspaceSnapshot manifest@(WorkspaceManifest _ _ _ state _) _ _ _) <- ExceptT (Store.readWorkspace workspace)
    (WorkspaceSnapshot (WorkspaceManifest base name explanation _ kind) target _ _,saved,report) <-
      case state of
        Accepted -> (live,SavedCapture,) <$> ExceptT (Store.readArchivedReport workspace)
        _ -> do
          candidate <- ExceptT (Store.loadCheckedCandidate workspace)
          pure $ case candidate of
            Just (Candidate (EvolutionContext _ _ _ snapshot) steps _) -> (snapshot,SavedCapture,Just steps)
            Nothing -> (live,LiveWorkspace,Nothing)
    path <- checked (rootLocation kb)
    previous <- ExceptT (Git.readTreeAt repository base (Subtree path))
    let before = filter (not . isRootMaterial . fst) (files previous)
        after = files target
        changes = [SourceChange key old new | key <- sort (nub (map fst before ++ map fst after)),
          let old = lookup key before, let new = lookup key after, old /= new]
        selectedManifest = if saved == SavedCapture then WorkspaceManifest base name explanation state kind else manifest
    -- Lifecycle state is current; explanation/base/source belong to the labelled capture.
    pure (EvolutionInspection selectedManifest saved report changes)
  where checked = either (throwE . pure . errorDiagnostic "inspection.source") pure

inspectOrigins :: Dhall.DhallHandling :> es => FileTree -> ExceptT [Diagnostic] (Eff es) [(PluginName,PluginOrigin)]
inspectOrigins code = forM entries $ \(name,bytes) -> do
  identity <- either (throwE . pure . errorDiagnostic "inspection.plugin") pure (pluginName name)
  origin <- ExceptT (decodeOrigin bytes)
  pure (identity,origin)
  where entries = [(name,bytes) | (path,bytes) <- files code,
          Just suffix <- [stripPrefix "plugins/packages/" (relativeName path)],
          let (name,rest) = break (== '/') suffix, rest == "/origin.dhall"]
