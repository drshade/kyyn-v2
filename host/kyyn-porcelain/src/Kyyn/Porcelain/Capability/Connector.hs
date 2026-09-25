module Kyyn.Porcelain.Capability.Connector
  ( listConfiguredConnectors, connectorConfigurationSchema, fetchConfiguredConnector
  , connectorCurrentEvidence, connectorFetchHistory, connectorEvidenceChanges, clearConnectorEvidence
  , connectorFetchOptions, listConnectorMethods, selectConnectorMethod, selectConnectorEvidence ) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Coerce (coerce)
import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport(..), CheckResult(..), errorDiagnostic)
import Kyyn.Domain.Contract (CheckedContract, contractId, contractShape)
import Kyyn.Domain.DataType (Shape)
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..), EvidenceSnapshotRef, EvidenceProducer(..), EvidenceCapture, FetchId, FetchSummary, EvidenceChangeSummary)
import Kyyn.Domain.Evolution (EvolutionId)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Git (GitRevision, TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Plugin
import Kyyn.Porcelain.Capability.EvidenceAcquisition (EvidenceAcquisition, fetchEvidence)
import Kyyn.Porcelain.Capability.EvidenceInspection (EvidenceInspection, currentEvidence, fetchHistory, evidenceChanges)
import qualified Kyyn.Porcelain.Capability.EvidenceStore as Store
import Kyyn.Porcelain.Capability.PluginPreparation
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Evolution
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadRootAt)
import Kyyn.Porcelain.Capability.Root (sourceCodeAt)
import Kyyn.Porcelain.Capability.RootStore (RootStore, rootLocation)
import Kyyn.Porcelain.Capability.RootExecution (RootExecution, prepareRoot, preparedPlugins)
import Kyyn.Porcelain.Capability.Validation (checkPreparedRoot)

clearConnectorEvidence :: Store.EvidenceStore :> es => PluginName -> ConnectorName -> Eff es Bool
clearConnectorEvidence plugin name = Store.clearEvidence (ConnectorInstanceRef plugin (coerce name))

listConfiguredConnectors :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> PluginName
  -> Eff es (Either [Diagnostic] [(ConnectorName,BindingName,ConnectorTypeName)])
listConfiguredConnectors kb revision workspace plugin = runExceptT $ do
  code <- sourceAt kb revision workspace
  plugins <- ExceptT (preparePlugins code)
  PreparedPlugin _ instances <- checked (selectedPlugin plugin plugins)
  pure [(name,binding,kind) | ConfiguredConnector name binding (PreparedConnector kind _ _ _ _ _ _) _ <- instances]

connectorConfigurationSchema :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> PluginName -> Eff es (Either [Diagnostic] Shape)
connectorConfigurationSchema kb revision workspace plugin = runExceptT $ do
  code <- sourceAt kb revision workspace
  packages <- ExceptT (preparePackages code)
  PreparedPackage _ _ connectors <- checked (selectedPackage plugin packages)
  pure (instanceShape [(name,contractShape config) | PreparedConnector name config _ _ _ _ _ <- connectors])

listConnectorMethods :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> PluginName -> ConnectorName -> Eff es (Either [Diagnostic] [PreparedMethod])
listConnectorMethods kb revision workspace plugin name = runExceptT $ do
  code <- sourceAt kb revision workspace
  plugins <- ExceptT (preparePlugins code)
  (_,ConfiguredConnector _ _ (PreparedConnector _ _ _ _ _ methods _) _) <- checked (selectedInstance plugin name plugins)
  pure methods

connectorFetchOptions :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> PluginName -> ConnectorName
  -> Eff es (Either [Diagnostic] (Maybe CheckedContract))
connectorFetchOptions kb revision workspace plugin name = runExceptT $ do
  code <- sourceAt kb revision workspace
  plugins <- ExceptT (preparePlugins code)
  (_,ConfiguredConnector _ _ (PreparedConnector _ _ _ _ _ _ options) _) <- checked (selectedInstance plugin name plugins)
  pure options

selectConnectorMethod :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> PluginName -> ConnectorName -> MethodName
  -> Eff es (Either [Diagnostic] (ConnectorInstanceRef,EvidenceProducer,CheckedContract,PreparedMethod))
selectConnectorMethod kb revision workspace plugin name method = runExceptT $ do
  code <- sourceAt kb revision workspace
  plugins <- ExceptT (preparePlugins code)
  (PreparedPackage _ identity _,ConfiguredConnector _ _ (PreparedConnector _ _ payload _ _ methods _) _) <-
    checked (selectedInstance plugin name plugins)
  case [m | m@(PreparedMethod n _ _ _ _) <- methods, n == method] of
    [selected] -> pure (ConnectorInstanceRef plugin (coerce name),EvidenceProducer identity (contractId payload),payload,selected)
    _ -> throwE [errorDiagnostic "plugin.method-unknown" ("No captured method named " ++ coerce method)]

connectorCurrentEvidence :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es, EvidenceInspection :> es)
  => KnowledgeBase -> GitRevision -> PluginName -> ConnectorName
  -> Eff es (Either [Diagnostic] EvidenceCapture)
connectorCurrentEvidence kb revision plugin name = runExceptT $ do
  (instanceRef,producer,payload) <- ExceptT (selectConnectorEvidence kb revision plugin name)
  ExceptT (currentEvidence instanceRef producer payload)

connectorFetchHistory :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es, EvidenceInspection :> es)
  => KnowledgeBase -> GitRevision -> PluginName -> ConnectorName
  -> Eff es (Either [Diagnostic] (EvidenceSnapshotRef,[FetchSummary]))
connectorFetchHistory kb revision plugin name = runExceptT $ do
  (instanceRef,producer,payload) <- ExceptT (selectConnectorEvidence kb revision plugin name)
  ExceptT (fetchHistory instanceRef producer payload)

connectorEvidenceChanges :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es, EvidenceInspection :> es)
  => KnowledgeBase -> GitRevision -> PluginName -> ConnectorName -> Maybe FetchId
  -> Eff es (Either [Diagnostic] (EvidenceSnapshotRef,[EvidenceChangeSummary]))
connectorEvidenceChanges kb revision plugin name since = runExceptT $ do
  (instanceRef,producer,payload) <- ExceptT (selectConnectorEvidence kb revision plugin name)
  ExceptT (evidenceChanges instanceRef producer payload since)

selectConnectorEvidence :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> PluginName -> ConnectorName
  -> Eff es (Either [Diagnostic] (ConnectorInstanceRef,EvidenceProducer,CheckedContract))
selectConnectorEvidence kb revision plugin name = runExceptT $ do
  code <- sourceAt kb revision Nothing
  plugins <- ExceptT (preparePlugins code)
  (PreparedPackage _ identity _,ConfiguredConnector _ _ (PreparedConnector _ _ payload _ _ _ _) _) <-
    checked (selectedInstance plugin name plugins)
  pure (ConnectorInstanceRef plugin (coerce name),EvidenceProducer identity (contractId payload),payload)

fetchConfiguredConnector
  :: (RootOpening :> es, RootExecution :> es, RootStore :> es, EvidenceAcquisition :> es)
  => KnowledgeBase -> GitRevision -> PluginName -> ConnectorName -> Maybe String
  -> Eff es (Either [Diagnostic] (EvidenceSnapshotRef, ValidationReport))
fetchConfiguredConnector kb@(KnowledgeBase repository _) revision plugin name supplied = runExceptT $ do
  location <- checked (pathResult (rootLocation kb))
  root <- ExceptT (loadRootAt repository revision (Subtree location))
  prepared <- ExceptT (prepareRoot root)
  validation <- ExceptT (Right <$> checkPreparedRoot prepared)
  report <- case validation of
    Rejected (ValidationReport diagnostics) -> throwE diagnostics
    Passed _ diagnostics -> pure diagnostics
  (PreparedPackage _ identity _,ConfiguredConnector _ _ (PreparedConnector _ _ payload entry _ _ options) config) <-
    checked (selectedInstance plugin name (preparedPlugins prepared))
  snapshot <- ExceptT (fetchEvidence (ConnectorInstanceRef plugin (coerce name)) identity payload entry config options supplied)
  pure (snapshot,report)

sourceAt :: (RootOpening :> es, Evolution.EvolutionStore :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> ExceptT [Diagnostic] (Eff es) FileTree
sourceAt kb revision workspace = ExceptT (sourceCodeAt kb revision workspace)

pathResult :: Either String a -> Either [Diagnostic] a
pathResult = either (Left . pure . errorDiagnostic "kb.path") Right
checked :: Either [Diagnostic] a -> ExceptT [Diagnostic] (Eff es) a
checked = ExceptT . pure
