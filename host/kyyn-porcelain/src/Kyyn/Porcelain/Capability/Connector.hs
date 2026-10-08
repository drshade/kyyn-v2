{-# LANGUAGE OverloadedStrings, DataKinds #-}
module Kyyn.Porcelain.Capability.Connector
  ( listConfiguredConnectors, connectorConfigurationSchema, fetchConfiguredConnector, loginConfiguredConnector
  , connectorCurrentEvidence, clearConnectorEvidence
  , connectorFetchOptions, listConnectorMethods, selectConnectorMethod, selectConnectorEvidence ) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Coerce (coerce)
import GHC.Records (getField)
import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic (Diagnostic(..), Severity(..), ValidationReport(..), CheckResult(..), checkReport, errorDiagnostic)
import Kyyn.Domain.Contract (CheckedContract, contractShape)
import Kyyn.Domain.DataType (Shape)
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..), EvidenceSnapshotRef, EvidenceCapture, SyncMode(..))
import Kyyn.Domain.Evolution (EvolutionId)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Git (GitRevision, TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Plugin
import Kyyn.Porcelain.Capability.EvidenceAcquisition (EvidenceAcquisition, fetchEvidence)
import Kyyn.Domain.EvidenceIndex (EvidenceSelection(EvidenceSelection))
import Kyyn.Porcelain.Capability.EvidenceInspection (EvidenceInspection, currentEvidence, selectEvidence)
import qualified Kyyn.Porcelain.Capability.EvidenceStore as Store
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.PluginLogin (PluginLogin, loginPlugin)
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Evolution
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadRootAt)
import Kyyn.Porcelain.Capability.Root (sourceCodeAt)
import Kyyn.Porcelain.Capability.RootStore (RootStore, rootLocation)
import Kyyn.Porcelain.Capability.RootExecution (RootExecution, prepareRoot, preparedPlugins)
import Kyyn.Porcelain.Capability.Validation (checkPreparedRoot)

clearConnectorEvidence :: Store.EvidenceStore :> es => PluginName -> ConnectorName -> Eff es Bool
clearConnectorEvidence plugin name = Store.clearEvidence (ConnectorInstanceRef plugin (coerce name))

loginConfiguredConnector :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es, PluginLogin :> es)
  => KnowledgeBase -> GitRevision -> PluginName -> ConnectorName -> Eff es (Either [Diagnostic] ValidationReport)
loginConfiguredConnector kb revision plugin name = runExceptT $ do
  code <- sourceAt kb revision Nothing
  plugins <- ExceptT (preparePlugins code)
  (package,instanceValue@(ConfiguredConnector _ _ connector config)) <-
    checked (selectedInstance plugin name plugins)
  (_,_,_,_,_,entry,_) <- checked (sourceDetails connector)
  selected <- maybe (throwE [errorDiagnostic "plugin.login-unsupported" "This connector does not provide a login operation."]) pure entry
  report <- ExceptT (validatePlugins [PreparedPlugin package [instanceValue]])
  case checkReport () report of
    Rejected (ValidationReport diagnostics) -> throwE diagnostics
    Passed _ _ -> pure ()
  _ <- ExceptT (loginPlugin selected config)
  pure report

listConfiguredConnectors :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> PluginName
  -> Eff es (Either [Diagnostic] [(ConnectorName,BindingName,ConnectorTypeName)])
listConfiguredConnectors kb revision workspace plugin = runExceptT $ do
  code <- sourceAt kb revision workspace
  plugins <- ExceptT (preparePlugins code)
  PreparedPlugin _ instances <- checked (selectedPlugin plugin plugins)
  pure [(name,binding,getField @"connectorType" connector) | ConfiguredConnector name binding connector _ <- instances]

connectorConfigurationSchema :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> PluginName -> Eff es (Either [Diagnostic] Shape)
connectorConfigurationSchema kb revision workspace plugin = runExceptT $ do
  code <- sourceAt kb revision workspace
  packages <- ExceptT (preparePackages code)
  PreparedPackage _ _ connectors <- checked (selectedPackage plugin packages)
  pure (instanceShape [(getField @"connectorType" c,contractShape (getField @"configContract" c)) | c <- connectors])

listConnectorMethods :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> PluginName -> ConnectorName -> Eff es (Either [Diagnostic] [PreparedMethod])
listConnectorMethods kb revision workspace plugin name = runExceptT $ do
  code <- sourceAt kb revision workspace
  plugins <- ExceptT (preparePlugins code)
  (_,ConfiguredConnector _ _ connector _) <- checked (selectedInstance plugin name plugins)
  (_,_,_,methods,_,_,_) <- checked (sourceDetails connector)
  pure methods

connectorFetchOptions :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> PluginName -> ConnectorName
  -> Eff es (Either [Diagnostic] (Maybe CheckedContract))
connectorFetchOptions kb revision workspace plugin name = runExceptT $ do
  code <- sourceAt kb revision workspace
  plugins <- ExceptT (preparePlugins code)
  (_,ConfiguredConnector _ _ connector _) <- checked (selectedInstance plugin name plugins)
  (_,_,_,_,options,_,_) <- checked (sourceDetails connector)
  pure options

selectConnectorMethod :: (RootOpening :> es, Evolution.EvolutionStore :> es, PluginPreparation :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> PluginName -> ConnectorName -> MethodName
  -> Eff es (Either [Diagnostic] (EvidenceSelection,CheckedContract,PreparedMethod))
selectConnectorMethod kb revision workspace plugin name method = runExceptT $ do
  code <- sourceAt kb revision workspace
  plugins <- ExceptT (preparePlugins code)
  (PreparedPackage _ identity _,ConfiguredConnector _ _ connector _) <-
    checked (selectedInstance plugin name plugins)
  (kind,payload,_,methods,_,_,_) <- checked (sourceDetails connector)
  case [m | m@(PreparedMethod n _ _ _ _) <- methods, n == method] of
    [selected] -> pure (EvidenceSelection (ConnectorInstanceRef plugin (coerce name)) kind identity,payload,selected)
    _ -> throwE [errorDiagnostic "plugin.method-unknown" ("No captured method named " ++ coerce method)]

connectorCurrentEvidence :: EvidenceInspection :> es
  => KnowledgeBase -> GitRevision -> PluginName -> ConnectorName
  -> Eff es (Either [Diagnostic] EvidenceCapture)
connectorCurrentEvidence kb revision plugin name = runExceptT $ do
  selection <- ExceptT (selectConnectorEvidence kb revision plugin name)
  ExceptT (currentEvidence selection)

selectConnectorEvidence :: EvidenceInspection :> es
  => KnowledgeBase -> GitRevision -> PluginName -> ConnectorName
  -> Eff es (Either [Diagnostic] EvidenceSelection)
selectConnectorEvidence = selectEvidence

fetchConfiguredConnector
  :: (RootOpening :> es, RootExecution :> es, RootStore :> es, EvidenceAcquisition :> es)
  => KnowledgeBase -> GitRevision -> PluginName -> ConnectorName -> Maybe String -> SyncMode
  -> Eff es (Either [Diagnostic] (EvidenceSnapshotRef, ValidationReport))
fetchConfiguredConnector kb@(KnowledgeBase repository _) revision plugin name supplied mode = runExceptT $ do
  location <- checked (pathResult (rootLocation kb))
  root <- ExceptT (loadRootAt repository revision (Subtree location))
  prepared <- ExceptT (prepareRoot root)
  validation <- ExceptT (Right <$> checkPreparedRoot prepared)
  report <- case validation of
    Rejected (ValidationReport diagnostics) -> throwE diagnostics
    Passed _ diagnostics -> pure diagnostics
  (PreparedPackage _ identity _,ConfiguredConnector _ _ connector config) <-
    checked (selectedInstance plugin name (preparedPlugins prepared))
  (kind,payload,entry,_,options,_,position) <- checked (sourceDetails connector)
  snapshot <- ExceptT (fetchEvidence (EvidenceSelection (ConnectorInstanceRef plugin (coerce name)) kind identity) payload entry config options position mode supplied)
  let ValidationReport warnings = report
      notes = [Diagnostic Warning "plugin.sync-stateless" "This connector has no sync position; --restart-sync has no effect." Nothing |
        mode == RestartSync, Nothing <- [position]]
  pure (snapshot,ValidationReport (warnings ++ notes))

sourceAt :: (RootOpening :> es, Evolution.EvolutionStore :> es)
  => KnowledgeBase -> GitRevision -> Maybe EvolutionId -> ExceptT [Diagnostic] (Eff es) FileTree
sourceAt kb revision workspace = ExceptT (sourceCodeAt kb revision workspace)

pathResult :: Either String a -> Either [Diagnostic] a
pathResult = either (Left . pure . errorDiagnostic "kb.path") Right
checked :: Either [Diagnostic] a -> ExceptT [Diagnostic] (Eff es) a
checked = ExceptT . pure
