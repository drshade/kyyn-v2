{-# LANGUAGE DataKinds, OverloadedStrings, OverloadedRecordDot, TypeApplications #-}
module Kyyn.Composition.Flows (dispatchFlows) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM, when)
import Data.List (nub)
import Data.Time (diffUTCTime)
import Kyyn.Plumbing.Capability.Clock (Clock, currentTime)
import Kyyn.Plumbing.Interpreter.Clock (runClockIO)
import Data.Aeson (Value(..), object, (.=), eitherDecodeStrict')
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, liftIO, (:>))
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Effectful.Error.Static (catchError)
import System.IO (hPutStrLn, stderr)
import Kyyn.Configuration (Host(..), SelectedKb(..))
import Kyyn.Composition.FlowValues (FlowValues(..), readFlowValues, readFlowValuesMany)
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
import Kyyn.Plumbing.Protocol.Interactive (describeWait)
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
import Kyyn.Porcelain.Capability.FlowEvents (FlowEvents, EventVisit(..), serviceEvents)
import Kyyn.Porcelain.Capability.PluginEvent (PluginEvent)
import Kyyn.Porcelain.Interpreter.FlowEvents (runFlowEvents)
import Kyyn.Porcelain.Interpreter.PluginEvent (runPluginEvent)
import Kyyn.Plumbing.Capability.HttpTransport (HttpTransport)
import Kyyn.Plumbing.Capability.PluginInteraction (Waiting)
import Kyyn.Plumbing.Interpreter.HttpTransport (runHttpTransportIO)
import Kyyn.Plumbing.Interpreter.PluginInteraction (runWaitingIO)
import Kyyn.Porcelain.Interpreter.FlowWorker (runFlowWorker)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead)
import Kyyn.Porcelain.Interpreter.RecipeRunStore (runRecipeRunStore)
import qualified Kyyn.Surfaces.Cli as Cli
import qualified Kyyn.Surfaces.Flows as View
import qualified Kyyn.Surfaces.Result as Result
import Kyyn.Surfaces.Result (Response, success, refusal, operationalFailure)

type Pinned = FlowEvents ': PluginEvent ': FlowWorker ': RecipeRunStore ': AppendJournal ': FlowStore ': PluginRead ': EvidenceStore ': BlobStorage
  ': DocumentPersistence ': Clock ': HttpTransport ': Waiting ': ModelTurn ': Judgement ': SecretStore ': GuestExecution ': Base

-- Resumption and inspection do not resolve Nix, inspect current source, or rebuild.
runPinned :: Host -> KnowledgeBase -> DirectoryScope -> Eff Pinned a -> IO (Either OperationalFailure a)
runPinned host kb scope = runBase host . runGuestExecution host.runtimeEnvironment
  . runSecretStoreIO scope . runJudgementIO . runModelTurnIO . runWaitingIO . runHttpTransportIO . runClockIO . runDocumentPersistenceIO
  . runBlobStorageIO scope . runEvidenceStore scope . runPluginRead . runFlowStore kb
  . runAppendJournalIO . runRecipeRunStore announce . runFlowWorker kb . runPluginEvent . runFlowEvents kb
  where announce header = liftIO (hPutStrLn stderr ("Attempt " ++ runIdText header.runId ++ ": /runs/" ++ runIdText header.runId))

dispatchFlows :: Host -> Cli.FlowCommand -> SelectedKb -> IO Response
dispatchFlows host command (SelectedKb kb revision _) = case knowledgeBaseScope kb of
  Left problem -> pure (refusal [errorDiagnostic "kb.path" problem])
  Right scope -> case command of
    Cli.StartFlow recipe key request -> withRuntime host $ \settings -> finish $
      runRuntime host settings . runDocumentPersistenceIO . runFlowStore kb . runPluginPreparation . runFlowPreparation . runFlow $
        startFlowAt kb revision recipe (Text.pack <$> key) (Text.pack <$> request) >>= either (pure . refusal) (present False)
    Cli.WorkFlows once -> worker scope once Nothing
    Cli.AwaitFlow identity -> await scope identity
    _ -> finish $ runPinned host kb scope $ case command of
      Cli.ListFlows -> do
        items <- listInstances
        rendered <- readFlowValuesMany items
        states <- forM (zip items rendered) $ \(item,values) -> do
          interrupted <- if item.status == Running then not <$> writerBusy item.instanceId else pure False
          let Result.Response _ value _ _ = presentValues interrupted item values
          pure (item,interrupted,value)
        pure (success (object ["instances" .= [value | (_,_,value) <- states]])
          (if null states then ["No interactive flows started."] else
            [Text.unpack (flowInstanceIdText item.instanceId) ++ "  " ++ Text.unpack (View.statusText item stopped) ++
              (if null item.blocked then "" else "  blocked") | (item,stopped,_) <- states]))
      Cli.ShowFlow identity -> inspect identity
      Cli.FulfilFlow identity selected key encoded -> case eitherDecodeStrict' (Text.encodeUtf8 (Text.pack encoded)) of
        Left message -> pure (refusal [errorDiagnostic "flow.reply-json" message])
        Right value | maybe False (Text.null . Text.strip . Text.pack) key -> pure (refusal [errorDiagnostic "flow.key" "Supply a nonempty delivery key"])
                    | otherwise -> do
          found <- readInstance identity
          case found of
            Nothing -> pure (refusal [flowProblem MissingInstance])
            Just item -> case selectWait selected item of
              Left problem -> pure (refusal [problem])
              Right wait -> do
                queued <- maybe (queueNewDelivery identity wait) (\chosen -> queueDelivery identity (Text.pack chosen) wait) key
                  (ReceivedFrom (ManualReply "cli")) value
                pure $ either (refusal . pure . flowProblem) deliveryResponse queued
      Cli.CancelFlow identity selected -> cancelInstance identity selected >>= operation
      Cli.RetryFlow identity -> do
        busy <- writerBusy identity
        if busy then pure (refusal [errorDiagnostic "flow.busy" "A worker owns this instance; retry after its attempt stops"])
          else retryInstance identity >>= operation
      Cli.ClearFlows identities descendants -> do
        items <- if descendants then listInstances else pure []
        cleared <- clearInstances (if descendants then subtree identities items else identities)
        pure (either (refusal . pure . flowProblem) (\removed -> success
          (object ["cleared" .= map flowInstanceIdText removed]) ["Cleared " ++ show (length removed) ++ " finished flow instances."]) cleared)
  where
    operation = either (pure . refusal . pure . flowProblem) (\item -> do
      stopped <- if item.status == Running then not <$> writerBusy item.instanceId else pure False
      present stopped item)
    inspect identity = readInstance identity >>= maybe (pure (refusal [flowProblem MissingInstance])) (\item -> do
      stopped <- if item.status == Running then not <$> writerBusy item.instanceId else pure False
      present stopped item)
    await scope identity = do
      state <- runPinned host kb scope (readInstance identity)
      case state of
        Left problem -> pure (operationalFailure problem)
        Right Nothing -> pure (refusal [flowProblem MissingInstance])
        Right (Just item) -> case item.status of
          Finished Completed{} -> finish (runPinned host kb scope (present False item))
          Finished (Failed problems) -> finish (runPinned host kb scope (refuseResult problems <$> present False item))
          Finished Cancelled -> finish (runPinned host kb scope (refuseResult [errorDiagnostic "flow.cancelled" "The flow was cancelled"] <$> present False item))
          _ | not (null item.blocked) -> finish (runPinned host kb scope (refuseResult item.blocked <$> present False item))
            | otherwise -> threadDelay 1000000 >> await scope identity
    worker scope once previous = do
      result <- runPinned host kb scope $ do
        items <- listInstances
        visits <- forM (filter eligible items) $ \item -> do
          visited <- catchError @OperationalFailure (Right <$> (do
            guest <- visitInstance item.instanceId
            events <- serviceEvents item.instanceId
            resumed <- if events.received then visitInstance item.instanceId else pure NoWork
            pure (if Blocked `elem` [guest,events.activity,resumed] then Blocked
              else if Advanced `elem` [guest,events.activity,resumed] then Advanced
              else if WriterBusy `elem` [guest,events.activity,resumed] then WriterBusy else NoWork))) (\_ problem -> pure (Left problem))
          pure (item.instanceId,visited)
        now <- currentTime
        latest <- listInstances
        let delays = [max 1000 (ceiling (diffUTCTime due now * 1000000)) |
              item <- latest, eligible item, wait <- item.waits, wait.waitStatus == Open,
              Just adapter <- [wait.adapter], null adapter.dispatchProblems,
              Just due <- [adapter.polling.nextAttempt], due > now]
        pure (visits,minimum (1000000 : delays))
      case result of
        Left problem -> pure (operationalFailure problem)
        Right (visits,idleDelay) -> do
          let messages = [Text.unpack (flowInstanceIdText identity) ++ "  " ++ either
                (Text.unpack . (.message) . operationalDiagnostic) (Text.unpack . visitText) visited | (identity,visited) <- visits]
              value = object ["visits" .= [object ["id" .= flowInstanceIdText identity,
                "outcome" .= either (const "blocked") visitText visited] | (identity,visited) <- visits]]
          if once then pure (success value (if null messages then ["No interactive flows to visit."] else messages))
          else do
            when (previous /= Just messages) (mapM_ (hPutStrLn stderr) messages)
            threadDelay idleDelay
            worker scope once (Just messages)

present :: (FlowStore :> es, DhallHandling :> es, Failure :> es) => Bool -> FlowInstance -> Eff es Response
present stopped item = presentValues stopped item <$> readFlowValues item

presentValues :: Bool -> FlowInstance -> FlowValues -> Response
presentValues stopped item values = success
  (View.instanceValue item stopped waits values.input values.output values.diagnostics)
  (View.instanceLines item stopped waits values.input values.output values.diagnostics)
  where waits = descriptors item

descriptors :: FlowInstance -> [(Text.Text,Value)]
descriptors item = [(wait.waitId,either (\message -> object ["unavailable" .= message]) id
  (describeWait wait)) | wait <- item.waits]

selectWait :: Maybe String -> FlowInstance -> Either Diagnostic Text.Text
selectWait (Just selected) _ = Right (Text.pack selected)
selectWait Nothing item = case [wait.waitId | wait <- item.waits, wait.waitStatus == Open, (case wait.kind of ChildWait{} -> False; _ -> True)] of
  [identity] -> Right identity
  identities -> Left (errorDiagnostic "flow.wait" ("Supply --wait WAIT_ID. Open reply waits: " ++
    if null identities then "none" else Text.unpack (Text.intercalate ", " identities)))

refuseResult :: [Diagnostic] -> Response -> Response
refuseResult problems (Result.Response _ value messages _) = Result.Response Result.Refused value messages problems

deliveryResponse :: FlowDelivery -> Response
deliveryResponse delivery = case delivery.outcome of
  Just ClosedWait -> refused "This wait is closed or unknown"
  Just Conflicting -> refused "This delivery conflicts with the accepted reply"
  Just (Invalid reason) -> refused (Text.unpack reason)
  _ -> shown
  where
    shown = success (View.deliveryValue delivery) [case delivery.outcome of
      Nothing -> "Reply queued. The worker validates it before resuming the flow."
      Just outcome -> "Delivery outcome: " ++ Text.unpack (View.deliveryOutcomeText outcome)]
    refused message = refuseResult [errorDiagnostic "flow.delivery" message] shown

visitText :: WorkerVisit -> Text.Text
visitText WriterBusy = "busy"
visitText NoWork = "no-work"
visitText Advanced = "advanced"
visitText Blocked = "blocked"

eligible :: FlowInstance -> Bool
eligible item = case item.launch.owner of
  External -> False
  Hosted{} -> not item.retryRequired && case item.status of
    Runnable -> True
    Running -> True
    Waiting -> True
    Finished{} -> False

subtree :: [FlowInstanceId] -> [FlowInstance] -> [FlowInstanceId]
subtree selected items =
  let next = nub (selected ++ [item.instanceId | item <- items, maybe False (`elem` selected) item.parent])
  in if next == selected then next else subtree next items
