{-# LANGUAGE DataKinds #-}
module Kyyn.Composition.Connectors (dispatchConnectors, dispatchEvidence) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Data.Coerce (coerce)
import Effectful (Eff)
import Kyyn.Configuration (Host, SelectedKb(..))
import Kyyn.Composition.Runtime
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport(..), errorDiagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Porcelain.Capability.Connector
import Kyyn.Porcelain.Capability.RootOpening (RootOpening)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.KnowledgeBase (knowledgeBaseScope)
import Kyyn.Domain.Plugin
import Kyyn.MicroHs.Toolchain (GuestToolchain)
import Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Capability.DhallHandling (renderType)
import Kyyn.Plumbing.Interpreter.EvidenceStore (runEvidenceStoreIO)
import Kyyn.Plumbing.Interpreter.FileAcquisition (runFileAcquisitionIO)
import Kyyn.Plumbing.Protocol.ConnectorConfig (instanceShape)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.EvidenceInspection (fetchHistory, evidenceChanges)
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Evolution
import Kyyn.Porcelain.Capability.WorkspaceStore (WorkspaceStore)
import Kyyn.Porcelain.Interpreter.EvidenceAcquisition (runEvidenceAcquisition)
import Kyyn.Porcelain.Interpreter.EvidenceInspection (runEvidenceInspection)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution)
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.Connectors
import Kyyn.Surfaces.Result (Response(..), refusal)

type Discovery = PluginPreparation ': Evolution.EvolutionStore ': WorkspaceStore ': RootOpening ': Runtime

runDiscovery :: Host -> GuestToolchain -> FileTree -> Eff Discovery a -> IO (Either OperationalFailure a)
runDiscovery host toolchain sdk = runRuntime host toolchain . runRootOpening sdk . runWorkspaceStore
  . runEvolutionStore . runPluginPreparation sdk

dispatchConnectors :: Host -> Cli.ConnectorCommand -> SelectedKb -> IO Response
dispatchConnectors host command (SelectedKb kb revision _) = withRuntime host $ \toolchain sdk -> case command of
  Cli.ListConnectors plugin workspace -> respond $ runDiscovery host toolchain sdk $ runExceptT $ do
    code <- sourceAt kb revision workspace
    plugins <- ExceptT (preparePlugins code)
    PreparedPlugin _ instances <- checked (selectedPlugin plugin plugins)
    pure (connectorListResult plugin [(name,binding,kind) |
      ConfiguredConnector name binding (PreparedConnector kind _ _ _ _) _ <- instances])
  Cli.ShowConnectorSchema plugin workspace -> respond $ runDiscovery host toolchain sdk $ runExceptT $ do
    code <- sourceAt kb revision workspace
    packages <- ExceptT (preparePackages code)
    PreparedPackage _ _ connectors <- checked (selectedPackage plugin packages)
    schema <- ExceptT (Right <$> renderType (instanceShape [(name,contractShape config) |
      PreparedConnector name config _ _ _ <- connectors]))
    pure (schemaResult plugin schema)

dispatchEvidence :: Host -> Cli.EvidenceCommand -> SelectedKb -> IO Response
dispatchEvidence host command (SelectedKb kb revision _) = withRuntime host $ \toolchain sdk -> case command of
  Cli.FetchConnector plugin name -> case knowledgeBaseScope kb of
    Left message -> pure (refusal [errorDiagnostic "kb.path" message])
    Right scope -> respond $ runRuntime host toolchain . runEvidenceStoreIO scope . runFileAcquisitionIO
      . runGuestExecution toolchain . runRootOpening sdk . runPluginPreparation sdk . runRootExecution sdk . runEvidenceAcquisition $ runExceptT $ do
        (snapshot,ValidationReport warnings) <- ExceptT (fetchConfiguredConnector kb revision plugin name)
        let Response outcome result humanLines diagnostics = fetchResult snapshot
        pure (Response outcome result humanLines (warnings ++ diagnostics))
  Cli.ListFetchHistory plugin name at -> inspectEvidence toolchain sdk plugin name $ \instanceRef producer payload ->
    fmap (fmap (uncurry historyResult)) (fetchHistory instanceRef producer payload (maybe CurrentEvidence AtFetch at))
  Cli.ListEvidenceChanges plugin name since at -> inspectEvidence toolchain sdk plugin name $ \instanceRef producer payload ->
    fmap (fmap (uncurry changesResult)) (evidenceChanges instanceRef producer payload (maybe CurrentEvidence AtFetch at) since)
  where
    inspectEvidence toolchain sdk plugin name action = case knowledgeBaseScope kb of
      Left message -> pure (refusal [errorDiagnostic "kb.path" message])
      Right scope -> respond $ runRuntime host toolchain . runEvidenceStoreIO scope
        . runRootOpening sdk . runWorkspaceStore . runEvolutionStore . runPluginPreparation sdk . runEvidenceInspection $ runExceptT $ do
          code <- sourceAt kb revision Nothing
          plugins <- ExceptT (preparePlugins code)
          (PreparedPackage _ identity _,ConfiguredConnector _ _ (PreparedConnector _ _ payload _ _) _) <-
            checked (selectedInstance plugin name plugins)
          ExceptT (action (ConnectorInstanceRef plugin (coerce name)) (EvidenceProducer identity (contractId payload)) payload)

checked :: Either [Diagnostic] a -> ExceptT [Diagnostic] (Eff es) a
checked = ExceptT . pure
respond :: IO (Either OperationalFailure (Either [Diagnostic] Response)) -> IO Response
respond = finish . fmap (fmap (either refusal id))
