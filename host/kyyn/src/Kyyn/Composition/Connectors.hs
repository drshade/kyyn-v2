{-# LANGUAGE DataKinds #-}
module Kyyn.Composition.Connectors (dispatchConnectors, dispatchEvidence) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Effectful (Eff)
import Kyyn.Configuration (Host, SelectedKb(..))
import Kyyn.Composition.Runtime
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport(..), errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Porcelain.Capability.Connector
import Kyyn.Porcelain.Capability.RootOpening (RootOpening)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.KnowledgeBase (knowledgeBaseScope)
import Kyyn.MicroHs.Toolchain (GuestToolchain)
import Kyyn.Plumbing.Capability.DhallHandling (renderType)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Plumbing.Interpreter.FileAcquisition (runFileAcquisitionIO)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation)
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
  Cli.ListConnectors plugin workspace -> respond $ runDiscovery host toolchain sdk $
    fmap (fmap (connectorListResult plugin)) (listConfiguredConnectors kb revision workspace plugin)
  Cli.ShowConnectorSchema plugin workspace -> respond $ runDiscovery host toolchain sdk $ runExceptT $ do
    shape <- ExceptT (connectorConfigurationSchema kb revision workspace plugin)
    schema <- ExceptT (Right <$> renderType shape)
    pure (schemaResult plugin schema)

dispatchEvidence :: Host -> Cli.EvidenceCommand -> SelectedKb -> IO Response
dispatchEvidence host command (SelectedKb kb revision _) = case command of
  Cli.ClearEvidence plugin name -> case knowledgeBaseScope kb of
    Left message -> pure (refusal [errorDiagnostic "kb.path" message])
    Right scope -> finish $ runBase host . runDocumentPersistenceIO . runEvidenceStore scope $ do
      existed <- clearConnectorEvidence plugin name
      pure (clearResult plugin name existed)
  Cli.FetchConnector plugin name -> withRuntime host $ \toolchain sdk -> case knowledgeBaseScope kb of
    Left message -> pure (refusal [errorDiagnostic "kb.path" message])
    Right scope -> respond $ runRuntime host toolchain . runDocumentPersistenceIO . runEvidenceStore scope . runFileAcquisitionIO
      . runRootOpening sdk . runPluginPreparation sdk . runRootExecution sdk . runEvidenceAcquisition $ runExceptT $ do
        (snapshot,ValidationReport warnings) <- ExceptT (fetchConfiguredConnector kb revision plugin name)
        let Response outcome result humanLines diagnostics = fetchResult snapshot
        pure (Response outcome result humanLines (warnings ++ diagnostics))
  Cli.ListFetchHistory plugin name -> withRuntime host $ \toolchain sdk -> inspectEvidence toolchain sdk $
    fmap (fmap (uncurry historyResult)) (connectorFetchHistory kb revision plugin name)
  Cli.ListEvidenceChanges plugin name since -> withRuntime host $ \toolchain sdk -> inspectEvidence toolchain sdk $
    fmap (fmap (uncurry changesResult)) (connectorEvidenceChanges kb revision plugin name since)
  where
    inspectEvidence toolchain sdk action = case knowledgeBaseScope kb of
      Left message -> pure (refusal [errorDiagnostic "kb.path" message])
      Right scope -> respond $ runRuntime host toolchain . runDocumentPersistenceIO . runEvidenceStore scope
        . runRootOpening sdk . runWorkspaceStore . runEvolutionStore . runPluginPreparation sdk . runEvidenceInspection $ action

respond :: IO (Either OperationalFailure (Either [Diagnostic] Response)) -> IO Response
respond = finish . fmap (fmap (either refusal id))
