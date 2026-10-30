{-# LANGUAGE DataKinds #-}
module Kyyn.Composition.Connectors (dispatchConnectors, dispatchEvidence) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Effectful (Eff)
import Kyyn.Configuration (Host(..), SelectedKb(..))
import Data.Maybe (isJust)
import System.Environment (lookupEnv)
import Kyyn.Plumbing.Interpreter.ConcurrentExecution (runConcurrentExecutionObserved)
import Kyyn.Composition.SyncTimings
import Kyyn.Composition.Runtime
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport(..), errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Porcelain.Capability.Connector
import Kyyn.Porcelain.Capability.RootOpening (RootOpening)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Contract (contractShape)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Domain.Evidence (Evidence(..), EvidencePayload(..))
import Kyyn.Porcelain.Capability.EvidenceInspection (readCurrentEvidence, readEvidenceBatch)
import qualified Data.Text as Text
import Kyyn.Domain.KnowledgeBase (knowledgeBaseScope)
import Kyyn.MicroHs.Toolchain (GuestToolchain)
import Kyyn.Plumbing.Capability.DhallHandling (renderType, decodeValue, encodeValue)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Plumbing.Interpreter.BlobStorage (runBlobStorageIO)
import Kyyn.Plumbing.Interpreter.ContentDigest (runContentDigest)
import Kyyn.Plumbing.Interpreter.FileAcquisition (runFileAcquisitionIO)
import Kyyn.Plumbing.Interpreter.HttpTransport (runHttpTransportIO)
import Kyyn.Plumbing.Interpreter.SecretStore (runSecretStoreIO)
import Kyyn.Plumbing.Interpreter.PluginInteraction (runWaitingIO, runLoginInteractionIO)
import Kyyn.Porcelain.Interpreter.PluginLogin (runPluginLogin)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation, PreparedMethod(..))
import Kyyn.Porcelain.Capability.PluginRead (callCapturedMethod)
import Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead)
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Evolution
import Kyyn.Porcelain.Capability.WorkspaceStore (WorkspaceStore)
import Kyyn.Porcelain.Interpreter.EvidenceAcquisition (runEvidenceAcquisition)
import Kyyn.Porcelain.Interpreter.EvidenceInspection (runEvidenceInspection)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Capability.Tool (ToolPreparation)
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.Connectors
import Kyyn.Surfaces.Result (Response(..), refusal)

type Discovery = Evolution.EvolutionStore ': WorkspaceStore ': RootOpening ': ToolPreparation ': PluginPreparation ': Runtime

runDiscovery :: Host -> GuestToolchain -> FileTree -> Eff Discovery a -> IO (Either OperationalFailure a)
runDiscovery host toolchain sdk = runRuntime host toolchain . runPluginPreparation sdk . runToolPreparation sdk
  . runRootOpening sdk . runWorkspaceStore . runEvolutionStore

dispatchConnectors :: Host -> Cli.ConnectorCommand -> SelectedKb -> IO Response
dispatchConnectors host command (SelectedKb kb revision _) = withRuntime host $ \toolchain sdk -> case command of
  Cli.LoginConnector plugin name -> case knowledgeBaseScope kb of
    Left message -> pure (refusal [errorDiagnostic "kb.path" message])
    Right scope -> respond $ runRuntime host toolchain . runHttpTransportIO . runSecretStoreIO scope
      . runWaitingIO . runLoginInteractionIO . runPluginPreparation sdk . runToolPreparation sdk
      . runRootOpening sdk . runWorkspaceStore . runEvolutionStore . runPluginLogin $ runExceptT $ do
        ValidationReport warnings <- ExceptT (loginConfiguredConnector kb revision plugin name)
        let Response outcome result humanLines diagnostics = loginResult plugin name
        pure (Response outcome result humanLines (warnings ++ diagnostics))
  Cli.ListConnectors plugin workspace -> respond $ runDiscovery host toolchain sdk $
    fmap (fmap (connectorListResult plugin)) (listConfiguredConnectors kb revision workspace plugin)
  Cli.ShowConnector plugin name workspace -> respond $ runDiscovery host toolchain sdk $ runExceptT $ do
    (options,report) <- ExceptT (connectorFetchOptions kb revision workspace plugin name)
    schema <- traverse (ExceptT . fmap Right . renderType . contractShape) options
    reportSchema <- traverse (ExceptT . fmap Right . renderType . contractShape) report
    pure (connectorResult plugin name schema reportSchema)
  Cli.ShowConnectorSchema plugin workspace -> respond $ runDiscovery host toolchain sdk $ runExceptT $ do
    shape <- ExceptT (connectorConfigurationSchema kb revision workspace plugin)
    schema <- ExceptT (Right <$> renderType shape)
    pure (schemaResult plugin schema)
  Cli.ListConnectorMethods plugin name workspace -> respond $ runDiscovery host toolchain sdk $
    fmap (fmap (methodListResult . map (\(PreparedMethod method description _ _ _) -> (method,description))))
      (listConnectorMethods kb revision workspace plugin name)
  Cli.ShowConnectorMethod plugin name method workspace -> respond $ runDiscovery host toolchain sdk $ runExceptT $ do
    (_,_,PreparedMethod _ description input output _) <- ExceptT (selectConnectorMethod kb revision workspace plugin name method)
    inputType <- ExceptT (Right <$> renderType (contractShape input))
    resultType <- ExceptT (Right <$> renderType (contractShape output))
    pure (methodResult method description inputType resultType)
  Cli.ExecuteConnectorMethod plugin name method inputText -> case knowledgeBaseScope kb of
    Left message -> pure (refusal [errorDiagnostic "kb.path" message])
    Right scope -> respond $ runRuntime host toolchain . runDocumentPersistenceIO . (runBlobStorageIO scope . runEvidenceStore scope)
      . runPluginPreparation sdk . runToolPreparation sdk . runRootOpening sdk . runWorkspaceStore . runEvolutionStore . runPluginRead $ runExceptT $ do
        (selection,payload,selected@(PreparedMethod _ _ input output _)) <-
          ExceptT (selectConnectorMethod kb revision Nothing plugin name method)
        value <- ExceptT (decodeValue (contractShape input) (Text.pack inputText))
        (CheckedValue _ result,blobs) <- ExceptT (callCapturedMethod selection payload selected value)
        rendered <- ExceptT (encodeValue (contractShape output) result)
        pure (methodOutputResult result rendered blobs)

dispatchEvidence :: Host -> Cli.EvidenceCommand -> SelectedKb -> IO Response
dispatchEvidence host@(Host _ _ _ _ _ _ timings) command (SelectedKb kb revision _) = case command of
  Cli.ClearEvidence plugin name -> case knowledgeBaseScope kb of
    Left message -> pure (refusal [errorDiagnostic "kb.path" message])
    Right scope -> finish $ runBase host . runDocumentPersistenceIO . (runBlobStorageIO scope . runEvidenceStore scope) $ do
      existed <- clearConnectorEvidence plugin name
      pure (clearResult plugin name existed)
  Cli.FetchConnector plugin name options mode -> do
    configured <- lookupEnv "KYYN_FETCH_CONCURRENCY"
    case fetchConcurrency configured of
      Left message -> pure (refusal [errorDiagnostic "sync.concurrency" message])
      Right width -> withRuntime host $ \toolchain sdk -> do
        sync <- newSyncTimings (isJust timings)
        withSyncReport sync $ case knowledgeBaseScope kb of
          Left message -> pure (refusal [errorDiagnostic "kb.path" message])
          Right scope -> respond $ runRuntime host toolchain . runDocumentPersistenceIO
            . runBlobStorageIO scope . observeBlobs sync . runEvidenceStore scope . observeEvidence sync . runFileAcquisitionIO
            . runHttpTransportIO . observeHttp sync . runSecretStoreIO scope . runWaitingIO . observeWaiting sync
            . runContentDigest . runConcurrentExecutionObserved width (observeConcurrent sync) . runPluginPreparation sdk . runToolPreparation sdk . runRootOpening sdk . runRootExecution sdk
            . runEvidenceAcquisition scope . observeAcquisition sync $ runExceptT $ do
              (snapshot,ValidationReport warnings) <- ExceptT (fetchConfiguredConnector kb revision plugin name options mode)
              let Response outcome result humanLines diagnostics = fetchResult snapshot
              pure (Response outcome result humanLines (warnings ++ diagnostics))
  Cli.ListCurrentEvidence plugin name -> inspectEvidence $
    fmap (fmap evidenceListResult) (connectorCurrentEvidence kb revision plugin name)
  Cli.ShowAllEvidence plugin name expected -> inspectEvidence $ runExceptT $ do
    selection <- ExceptT (selectConnectorEvidence kb revision plugin name)
    evidenceBatchResult <$> ExceptT (readEvidenceBatch selection expected)
  Cli.ShowCurrentEvidence plugin name key -> inspectEvidence $ runExceptT $ do
    selection <- ExceptT (selectConnectorEvidence kb revision plugin name)
    (snapshot,latest,payload,found,blobs,report) <- ExceptT (readCurrentEvidence selection key)
    case found of
      Nothing -> pure (refusal [errorDiagnostic "evidence.not-found" "No current evidence with this ID. Use evidence list to find current items."])
      Just item@(Evidence _ _ Truncated) -> pure (evidenceItemResult snapshot latest key item blobs report "Payload: truncated")
      Just item@(Evidence _ _ (Available (CheckedValue _ value))) -> do
        rendered <- ExceptT (encodeValue (contractShape payload) value)
        pure (evidenceItemResult snapshot latest key item blobs report rendered)
  where
    inspectEvidence action = case knowledgeBaseScope kb of
      Left message -> pure (refusal [errorDiagnostic "kb.path" message])
      Right scope -> respond $ runBase host . runDocumentPersistenceIO . (runBlobStorageIO scope . runEvidenceStore scope)
        . runEvidenceInspection $ action

respond :: IO (Either OperationalFailure (Either [Diagnostic] Response)) -> IO Response
respond = finish . fmap (fmap (either refusal id))

fetchConcurrency :: Maybe String -> Either String Int
fetchConcurrency Nothing = Right 4
fetchConcurrency (Just value) = case reads value of
  [(width,"")] | width >= 1 && width <= 8 && show width == value -> Right width
  _ -> Left "KYYN_FETCH_CONCURRENCY must be a canonical integer from 1 through 8."
