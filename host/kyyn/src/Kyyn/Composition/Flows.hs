{-# LANGUAGE DataKinds, OverloadedStrings, OverloadedRecordDot, TypeApplications #-}
module Kyyn.Composition.Flows (dispatchFlows) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM, when)
import Data.Aeson (Value(..), object, (.=), eitherDecodeStrict')
import Data.Aeson.Types (parseEither)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, liftIO)
import Effectful.Error.Static (catchError)
import System.IO (hPutStrLn, stderr)
import Kyyn.Configuration (Host(..), SelectedKb(..))
import Kyyn.Composition.Runtime (Base, runBase, runRuntime, withRuntime, finish)
import Kyyn.Domain.Diagnostic (Diagnostic(..), errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure, operationalDiagnostic)
import Kyyn.Domain.FlowInstance
import Kyyn.Domain.KnowledgeBase (KnowledgeBase, knowledgeBaseScope)
import Kyyn.Domain.Path (DirectoryScope)
import Kyyn.Domain.RecipeRun (RecipeRunHeader(..), runIdText)
import Kyyn.Plumbing.Capability.AppendJournal (AppendJournal)
import Kyyn.Plumbing.Capability.BlobStorage (BlobStorage)
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.Judgement (Judgement)
import Kyyn.Plumbing.Capability.ModelTurn (ModelTurn)
import Kyyn.Plumbing.Capability.SecretStore (SecretStore)
import Kyyn.Plumbing.Interpreter.AppendJournal (runAppendJournalIO)
import Kyyn.Plumbing.Interpreter.BlobStorage (runBlobStorageIO)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Plumbing.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Interpreter.Judgement (runJudgementIO)
import Kyyn.Plumbing.Interpreter.ModelTurn (runModelTurnIO)
import Kyyn.Plumbing.Interpreter.SecretStore (runSecretStoreIO)
import Kyyn.Plumbing.Protocol.Tool (decodeFlowValue)
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore)
import Kyyn.Porcelain.Capability.Flow (startFlowAt, flowProblem)
import Kyyn.Porcelain.Capability.FlowStore
import Kyyn.Porcelain.Capability.FlowWorker
import Kyyn.Porcelain.Capability.PluginRead (PluginRead)
import Kyyn.Porcelain.Capability.RecipeRunStore (RecipeRunStore)
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Porcelain.Interpreter.Flow (runFlow)
import Kyyn.Porcelain.Interpreter.FlowPreparation (runFlowPreparation)
import Kyyn.Porcelain.Interpreter.FlowStore (runFlowStore)
import Kyyn.Porcelain.Interpreter.FlowWorker (runFlowWorker)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead)
import Kyyn.Porcelain.Interpreter.RecipeRunStore (runRecipeRunStore)
import qualified Kyyn.Surfaces.Cli as Cli
import qualified Kyyn.Surfaces.Flows as View
import Kyyn.Surfaces.Result (Response, success, refusal, operationalFailure)

type Pinned = FlowWorker ': RecipeRunStore ': AppendJournal ': FlowStore ': PluginRead ': EvidenceStore ': BlobStorage
  ': DocumentPersistence ': ModelTurn ': Judgement ': SecretStore ': GuestExecution ': Base

-- Resumption and inspection do not resolve Nix, inspect current source, or rebuild.
runPinned :: Host -> KnowledgeBase -> DirectoryScope -> Eff Pinned a -> IO (Either OperationalFailure a)
runPinned host kb scope = runBase host . runGuestExecution host.runtimeEnvironment
  . runSecretStoreIO scope . runJudgementIO . runModelTurnIO . runDocumentPersistenceIO
  . runBlobStorageIO scope . runEvidenceStore scope . runPluginRead . runFlowStore kb
  . runAppendJournalIO . runRecipeRunStore announce . runFlowWorker kb
  where announce header = liftIO (hPutStrLn stderr ("Attempt " ++ runIdText header.runId ++ ": /runs/" ++ runIdText header.runId))

dispatchFlows :: Host -> Cli.FlowCommand -> SelectedKb -> IO Response
dispatchFlows host command (SelectedKb kb revision _) = case knowledgeBaseScope kb of
  Left problem -> pure (refusal [errorDiagnostic "kb.path" problem])
  Right scope -> case command of
    Cli.StartFlow recipe key request -> withRuntime host $ \settings -> finish $
      runRuntime host settings . runDocumentPersistenceIO . runFlowStore kb . runPluginPreparation . runFlowPreparation . runFlow $
        either refusal (present False) <$> startFlowAt kb revision recipe (Text.pack key) (Text.pack <$> request)
    Cli.WorkFlows once -> worker scope once Nothing
    Cli.AwaitFlow identity -> await scope identity
    _ -> finish $ runPinned host kb scope $ case command of
      Cli.ListFlows -> do
        items <- listInstances
        states <- forM items $ \item -> do
          interrupted <- if item.status == Running then not <$> writerBusy item.instanceId else pure False
          pure (item,interrupted)
        pure (success (object ["instances" .= [View.instanceValue item stopped (descriptors item) | (item,stopped) <- states]])
          (if null states then ["No interactive flows started."] else
            [Text.unpack (flowInstanceIdText item.instanceId) ++ "  " ++ Text.unpack (View.statusText item stopped) ++
              (if null item.blocked then "" else "  blocked") | (item,stopped) <- states]))
      Cli.ShowFlow identity -> inspect identity
      Cli.FulfilFlow identity wait key encoded -> case eitherDecodeStrict' (Text.encodeUtf8 (Text.pack encoded)) of
        Left message -> pure (refusal [errorDiagnostic "flow.reply-json" message])
        Right value | null key -> pure (refusal [errorDiagnostic "flow.key" "Supply a nonempty delivery key"])
                    | otherwise -> do
          queued <- queueDelivery identity (Text.pack key) (Text.pack wait) (ManualReply "cli") value
          pure $ either (refusal . pure . flowProblem) (\delivery -> success (View.deliveryValue delivery)
            [case delivery.outcome of
              Nothing -> "Reply queued. The worker validates it before resuming the flow."
              Just outcome -> "Delivery outcome: " ++ show outcome]) queued
      Cli.CancelFlow identity selected -> cancelInstance identity selected >>= operation
      Cli.RetryFlow identity -> do
        busy <- writerBusy identity
        if busy then pure (refusal [errorDiagnostic "flow.busy" "A worker owns this instance; retry after its attempt stops"])
          else retryInstance identity >>= operation
      Cli.ClearFlows identities -> do
        cleared <- clearInstances identities
        pure (either (refusal . pure . flowProblem) (\removed -> success
          (object ["cleared" .= map flowInstanceIdText removed]) ["Cleared " ++ show (length removed) ++ " finished flow instances."]) cleared)
  where
    operation = either (pure . refusal . pure . flowProblem) (\item -> do
      stopped <- if item.status == Running then not <$> writerBusy item.instanceId else pure False
      pure (present stopped item))
    inspect identity = readInstance identity >>= maybe (pure (refusal [flowProblem MissingInstance])) (\item -> do
      stopped <- if item.status == Running then not <$> writerBusy item.instanceId else pure False
      pure (present stopped item))
    await scope identity = do
      state <- runPinned host kb scope (readInstance identity)
      case state of
        Left problem -> pure (operationalFailure problem)
        Right Nothing -> pure (refusal [flowProblem MissingInstance])
        Right (Just item) -> case item.status of
          Finished{} -> pure (present False item)
          _ | not (null item.blocked) -> pure (refusal item.blocked)
            | otherwise -> threadDelay 1000000 >> await scope identity
    worker scope once previous = do
      result <- runPinned host kb scope $ do
        items <- listInstances
        forM items $ \item -> do
          visited <- catchError @OperationalFailure (Right <$> visitInstance item.instanceId) (\_ problem -> pure (Left problem))
          pure (item.instanceId,visited)
      case result of
        Left problem -> pure (operationalFailure problem)
        Right visits -> do
          let messages = [Text.unpack (flowInstanceIdText identity) ++ "  " ++ either
                (Text.unpack . (.message) . operationalDiagnostic) show visited | (identity,visited) <- visits]
              value = object ["visits" .= [object ["id" .= flowInstanceIdText identity,
                "outcome" .= either (const "blocked") (Text.toLower . Text.pack . show) visited] | (identity,visited) <- visits]]
          if once then pure (success value (if null messages then ["No interactive flows to visit."] else messages))
          else do
            when (previous /= Just messages) (mapM_ (hPutStrLn stderr) messages)
            threadDelay 1000000
            worker scope once (Just messages)

present :: Bool -> FlowInstance -> Response
present stopped item = success (View.instanceValue item stopped (descriptors item)) (View.instanceLines item stopped)

descriptors :: FlowInstance -> [(Text.Text,Value)]
descriptors item = [(wait.waitId,either (\message -> object ["unavailable" .= message]) id
  (parseEither decodeFlowValue wait.descriptor)) | wait <- item.waits]
