{-# LANGUAGE GADTs, LambdaCase, OverloadedRecordDot, OverloadedStrings, TypeApplications #-}
module Kyyn.Porcelain.Interpreter.FlowEvents (runFlowEvents) where

import Agentic.Aeson (toAeson)
import Control.Monad (forM)
import Data.List (find)
import Effectful (Eff, (:>), raise)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (catchError)
import Kyyn.Plumbing.Capability.Clock (Clock, currentTime)
import qualified Kyyn.Domain.FlowPolling as Polling
import Kyyn.Domain.FlowInstance
import Kyyn.Domain.FlowClosure (FlowDeclaration(..))
import Kyyn.Domain.Contract (contractShape)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Protocol.Interactive (eventWaitRequest)
import Kyyn.Porcelain.Capability.FlowEvents
import Kyyn.Porcelain.Capability.FlowWorker (WorkerVisit(..))
import Kyyn.Porcelain.Capability.FlowStore
import Kyyn.Porcelain.Capability.FlowPreparation (FlowBundle(..), PreparedFlowEntry(..))
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedEvent(..), ConfiguredConnector(..))
import Kyyn.Porcelain.Capability.PluginEvent (PluginEvent, dispatchEvent, pollEvent)
import Kyyn.Porcelain.Interpreter.FlowLocks (tryFlowAdapterLock)
import Kyyn.Porcelain.Protocol.EventBindings (checkEventWait, resolveEventInstance)
import Kyyn.Types.EventWait (EventWaitRequest(..))
import Kyyn.Types.KnowledgeBase (InteractionBindings(..))
import Kyyn.Types.Plugin (RepeatSafety(..), Seconds(..))

-- Adapter ownership never nests a journal lock. Results are committed before
-- ownership is released, including when cancellation closes the wait in-flight.
runFlowEvents :: (FlowStore :> es, PluginEvent :> es, DocumentPersistence :> es,
  DhallHandling :> es, Failure :> es, Clock :> es) => KnowledgeBase -> Eff (FlowEvents : es) a -> Eff es a
runFlowEvents kb = interpret $ \_ (ServiceEvents identity) -> do
  now <- currentTime
  readInstance identity >>= \case
    Just current | active current && any (actionable now) current.waits ->
      maybe (EventVisit WriterBusy False) id <$> tryFlowAdapterLock kb identity (raise (visit identity))
    _ -> pure (EventVisit NoWork False)
  where
    active current = not current.retryRequired && case current.status of Finished{} -> False; _ -> True
    actionable now wait = wait.waitStatus == Open && case wait.adapter of
      Just state -> null state.dispatchProblems && (state.dispatch `elem` [Pending,Started] || Polling.pollDue now wait)
      _ -> False
    visit identity = do
      now <- currentTime
      readInstance identity >>= \case
        Just current | active current -> do
          outcomes <- forM [wait.waitId | wait <- current.waits, actionable now wait] (service identity)
          pure (EventVisit (if any ((== Blocked) . (.activity)) outcomes then Blocked else if any ((== Advanced) . (.activity)) outcomes then Advanced else NoWork) (any (.received) outcomes))
        _ -> pure (EventVisit NoWork False)
    service identity key = do
      now <- currentTime
      readInstance identity >>= \case
        Just current | active current -> case find ((== key) . (.waitId)) current.waits of
          Just wait | actionable now wait, EventWait reference <- wait.kind ->
            case current.launch.owner of
              Hosted bundleId recipe -> readExecutionBundle bundleId >>= \case
                Left problems -> block identity key problems
                Right bundle -> case [entry | entry <- bundle.closure, entry.declaration.recipe == recipe] of
                  [entry] -> case do
                    request <- either (Left . pure . errorDiagnostic "flow.event-request") Right (eventWaitRequest wait.descriptor)
                    _ <- checkEventWait entry.declaration.bindings.events bundle.plugins request
                    (config,event) <- resolveEventInstance reference bundle.plugins
                    pure (request,config,event) of
                      Left problems -> block identity key problems
                      Right (request,ConfiguredConnector _ _ _ (CheckedValue _ config),PreparedEvent _ _ (Seconds interval) input reply cursor poll dispatch) ->
                        if Polling.pollDue now wait then do
                          started <- beginPoll identity key now (fromInteger interval)
                          case started of
                            Right True -> catchError @Failure.OperationalFailure
                              (do
                                requestCheck <- encodeValue (contractShape input) (toAeson request.payload)
                                case requestCheck of
                                  Left problems -> pollFailure identity key problems
                                  Right _ -> pollEvent poll config (flowInstanceIdText identity <> ":" <> key) (toAeson request.payload) (wait.adapter >>= (.cursor)) >>= \case
                                    Left problems -> pollFailure identity key problems
                                    Right (arrivals,nextCursor) -> do
                                      checkedReplies <- forM arrivals (encodeValue (contractShape reply) . snd)
                                      checkedCursor <- encodeValue (contractShape cursor) nextCursor
                                      case concat [problems | Left problems <- checkedCursor : checkedReplies] of
                                        [] -> completePoll identity key arrivals nextCursor >>= \case
                                          Right queued -> pure (EventVisit Advanced queued)
                                          Left problem -> pollFailure identity key [errorDiagnostic "flow.poll" (show problem)]
                                        problems -> pollFailure identity key problems)
                              (\_ problem -> pollFailure identity key [Failure.operationalDiagnostic problem])
                            Right False -> pure (EventVisit NoWork False)
                            Left problem -> pollFailure identity key [errorDiagnostic "flow.poll" (show problem)]
                        else case dispatch of
                          Nothing -> block identity key [errorDiagnostic "flow.dispatch" "Pending event has no captured dispatch entry"]
                          Just (program,safety)
                            | Just state <- wait.adapter, state.dispatch == Started, safety == RequireExplicitRetry ->
                                blockAfterStart safety identity key []
                            | otherwise -> encodeValue (contractShape input) (toAeson request.payload) >>= \case
                                Left problems -> block identity key problems
                                Right _ -> do
                                  started <- beginDispatch identity key
                                  case started of
                                    Right True -> catchError @Failure.OperationalFailure
                                      (dispatchEvent program config (flowInstanceIdText identity <> ":" <> key) (toAeson request.payload) >>= \case
                                        Left problems -> blockAfterStart safety identity key problems
                                        Right value -> encodeValue (contractShape cursor) value >>= \case
                                          Left problems -> blockAfterStart safety identity key problems
                                          Right _ -> completeDispatch identity key value >>= \case
                                            Right () -> pure (EventVisit Advanced False)
                                            Left problem -> blockAfterStart safety identity key [errorDiagnostic "flow.dispatch" (show problem)])
                                      (\_ problem -> blockAfterStart safety identity key [Failure.operationalDiagnostic problem])
                                    Right False -> pure (EventVisit NoWork False)
                                    Left problem -> block identity key [errorDiagnostic "flow.dispatch" (show problem)]
                  _ -> block identity key [errorDiagnostic "flow.dispatch" "Captured recipe is missing"]
              External -> pure (EventVisit NoWork False)
          _ -> pure (EventVisit NoWork False)
        _ -> pure (EventVisit NoWork False)
    blockAfterStart safety identity key problems = block identity key
      (problems ++ [errorDiagnostic "flow.dispatch-uncertain"
        "The provider may already have received this request. flow retry sends it again; confirm that repeating it is appropriate."
        | safety == RequireExplicitRetry])
    block identity key problems = blockDispatch identity key problems >>= \case
      Left _ -> pure (EventVisit Blocked False)
      Right () -> pure (EventVisit Blocked False)
    pollFailure identity key problems = failPoll identity key problems >> pure (EventVisit Blocked False)
