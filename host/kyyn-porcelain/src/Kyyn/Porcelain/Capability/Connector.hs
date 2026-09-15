module Kyyn.Porcelain.Capability.Connector
  ( listConfiguredConnectors, connectorConfigurationSchema, fetchConfiguredConnector
  , connectorFetchHistory, connectorEvidenceChanges ) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Coerce (coerce)
import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport(..), CheckResult(..), errorDiagnostic)
import Kyyn.Domain.Contract (CheckedContract, contractId, contractShape)
import Kyyn.Domain.DataType (Shape)
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..), EvidenceSnapshotRef, EvidenceProducer(..), FetchId, FetchSummary, EvidenceChangeSummary)
import Kyyn.Domain.Evolution (EvolutionId, EvolutionWorkspace(..))
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Git (GitRevision, TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Plugin
import Kyyn.Domain.Root (SourceRoot(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..))
import Kyyn.Porcelain.Capability.EvidenceAcquisition (EvidenceAcquisition, fetchEvidence)
import Kyyn.Porcelain.Capability.EvidenceInspection (EvidenceInspection, fetchHistory, evidenceChanges)
import Kyyn.Porcelain.Capability.PluginPreparation
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Evolution
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadSourceAt, loadRootAt)
import Kyyn.Porcelain.Capability.RootStore (RootStore, rootLocation)
import Kyyn.Porcelain.Capability.RootExecution (RootExecution, prepareRoot, preparedPlugins)
import Kyyn.Porcelain.Capability.Validation (checkPreparedRoot)

listConfiguredConnectors :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> PluginName
  -> Eff es (Either [Diagnostic] [(ConnectorName,BindingName,ConnectorTypeName)])
listConfiguredConnectors kb revision workspace plugin = runExceptT $ do
  code <- sourceAt kb revision workspace
  plugins <- ExceptT (preparePlugins code)
  PreparedPlugin _ instances <- checked (selectedPlugin plugin plugins)
  pure [(name,binding,kind) | ConfiguredConnector name binding (PreparedConnector kind _ _ _ _) _ <- instances]

connectorConfigurationSchema :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> PluginName -> Eff es (Either [Diagnostic] Shape)
connectorConfigurationSchema kb revision workspace plugin = runExceptT $ do
  code <- sourceAt kb revision workspace
  packages <- ExceptT (preparePackages code)
  PreparedPackage _ _ connectors <- checked (selectedPackage plugin packages)
  pure (instanceShape [(name,contractShape config) | PreparedConnector name config _ _ _ <- connectors])

connectorFetchHistory :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es, EvidenceInspection :> es)
  => KnowledgeBase -> GitRevision -> PluginName -> ConnectorName
  -> Eff es (Either [Diagnostic] (EvidenceSnapshotRef,[FetchSummary]))
connectorFetchHistory kb revision plugin name = runExceptT $ do
  (instanceRef,producer,payload) <- evidenceContext kb revision plugin name
  ExceptT (fetchHistory instanceRef producer payload)

connectorEvidenceChanges :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es, EvidenceInspection :> es)
  => KnowledgeBase -> GitRevision -> PluginName -> ConnectorName -> Maybe FetchId
  -> Eff es (Either [Diagnostic] (EvidenceSnapshotRef,[EvidenceChangeSummary]))
connectorEvidenceChanges kb revision plugin name since = runExceptT $ do
  (instanceRef,producer,payload) <- evidenceContext kb revision plugin name
  ExceptT (evidenceChanges instanceRef producer payload since)

evidenceContext :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> PluginName -> ConnectorName
  -> ExceptT [Diagnostic] (Eff es) (ConnectorInstanceRef,EvidenceProducer,CheckedContract)
evidenceContext kb revision plugin name = do
  code <- sourceAt kb revision Nothing
  plugins <- ExceptT (preparePlugins code)
  (PreparedPackage _ identity _,ConfiguredConnector _ _ (PreparedConnector _ _ payload _ _) _) <-
    checked (selectedInstance plugin name plugins)
  pure (ConnectorInstanceRef plugin (coerce name),EvidenceProducer identity (contractId payload),payload)

fetchConfiguredConnector
  :: (RootOpening :> es, RootExecution :> es, RootStore :> es, EvidenceAcquisition :> es)
  => KnowledgeBase -> GitRevision -> PluginName -> ConnectorName
  -> Eff es (Either [Diagnostic] (EvidenceSnapshotRef, ValidationReport))
fetchConfiguredConnector kb@(KnowledgeBase repository _) revision plugin name = runExceptT $ do
  location <- checked (pathResult (rootLocation kb))
  root <- ExceptT (loadRootAt repository revision (Subtree location))
  prepared <- ExceptT (prepareRoot root)
  validation <- ExceptT (Right <$> checkPreparedRoot prepared)
  report <- case validation of
    Rejected (ValidationReport diagnostics) -> throwE diagnostics
    Passed _ diagnostics -> pure diagnostics
  (PreparedPackage _ identity _,ConfiguredConnector _ _ (PreparedConnector _ _ payload entry _) config) <-
    checked (selectedInstance plugin name (preparedPlugins prepared))
  snapshot <- ExceptT (fetchEvidence (ConnectorInstanceRef plugin (coerce name)) identity payload entry config)
  pure (snapshot,report)

sourceAt :: (RootOpening :> es, Evolution.EvolutionStore :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> ExceptT [Diagnostic] (Eff es) FileTree
sourceAt kb@(KnowledgeBase repository _) revision workspace = case workspace of
  Nothing -> do
    location <- checked (pathResult (rootLocation kb))
    SourceRoot _ code _ _ <- ExceptT (loadSourceAt repository revision (Subtree location))
    pure code
  Just identity -> do
    WorkspaceSnapshot _ _ code _ _ <- ExceptT (Evolution.readWorkspace (EvolutionWorkspace kb identity))
    pure code

selectedPackage :: PluginName -> [PreparedPackage] -> Either [Diagnostic] PreparedPackage
selectedPackage name packages = case [package | package@(PreparedPackage actual _ _) <- packages, name == actual] of
  [package] -> Right package
  _ -> Left [errorDiagnostic "plugin.unknown" ("No installed plugin named " ++ pluginNameText name)]

selectedPlugin :: PluginName -> [PreparedPlugin] -> Either [Diagnostic] PreparedPlugin
selectedPlugin name plugins = case [plugin | plugin@(PreparedPlugin (PreparedPackage actual _ _) _) <- plugins, name == actual] of
  [plugin] -> Right plugin
  _ -> Left [errorDiagnostic "plugin.unknown" ("No installed plugin named " ++ pluginNameText name)]

selectedInstance :: PluginName -> ConnectorName -> [PreparedPlugin] -> Either [Diagnostic] (PreparedPackage,ConfiguredConnector)
selectedInstance plugin name plugins = do
  PreparedPlugin package instances <- selectedPlugin plugin plugins
  case [instanceValue | instanceValue@(ConfiguredConnector actual _ _ _) <- instances, actual == name] of
    [value] -> Right (package,value)
    _ -> Left [errorDiagnostic "plugin.instance-unknown" ("No configured connector " ++ pluginNameText plugin ++ "/" ++ coerce name)]

pathResult :: Either String a -> Either [Diagnostic] a
pathResult = either (Left . pure . errorDiagnostic "kb.path") Right
checked :: Either [Diagnostic] a -> ExceptT [Diagnostic] (Eff es) a
checked = ExceptT . pure
