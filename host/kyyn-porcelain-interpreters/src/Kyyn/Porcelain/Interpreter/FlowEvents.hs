{-# LANGUAGE GADTs, LambdaCase, OverloadedRecordDot, OverloadedStrings, TypeApplications #-}
module Kyyn.Porcelain.Interpreter.FlowEvents (runFlowEvents) where

import Agentic.Aeson (toAeson)
import Control.Monad (forM)
import Data.List (find)
import Effectful (Eff, (:>), raise)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (catchError)
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
import Kyyn.Porcelain.Capability.PluginEvent (PluginEvent, dispatchEvent)
import Kyyn.Porcelain.Interpreter.FlowLocks (tryFlowAdapterLock)
import Kyyn.Porcelain.Protocol.EventBindings (checkEventWait, resolveEventInstance)
import Kyyn.Types.EventWait (EventWaitRequest(..))
import Kyyn.Types.KnowledgeBase (InteractionBindings(..))
import Kyyn.Types.Plugin (RepeatSafety(..))

-- Adapter ownership never nests a journal lock. Results are committed before
-- ownership is released, including when cancellation closes the wait in-flight.
runFlowEvents :: (FlowStore :> es, PluginEvent :> es, DocumentPersistence :> es,
  DhallHandling :> es, Failure :> es) => KnowledgeBase -> Eff (FlowEvents : es) a -> Eff es a
runFlowEvents kb = interpret $ \_ (DispatchEvents identity) -> readInstance identity >>= \case
  Just current | active current && any actionable current.waits ->
    maybe WriterBusy id <$> tryFlowAdapterLock kb identity (raise (visit identity))
  _ -> pure NoWork
  where
    active current = not current.retryRequired && case current.status of Finished{} -> False; _ -> True
    actionable wait = wait.waitStatus == Open && case wait.adapter of
      Just state -> null state.dispatchProblems && state.dispatch `elem` [Pending,Started]
      _ -> False
    visit identity = readInstance identity >>= \case
      Just current | active current -> do
        outcomes <- forM [wait.waitId | wait <- current.waits, actionable wait] (service identity)
        pure (if Blocked `elem` outcomes then Blocked else if Advanced `elem` outcomes then Advanced else NoWork)
      _ -> pure NoWork
    service identity key = readInstance identity >>= \case
      Just current | active current -> case find ((== key) . (.waitId)) current.waits of
        Just wait | actionable wait, EventWait reference <- wait.kind ->
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
                    Right (request,ConfiguredConnector _ _ _ (CheckedValue _ config),PreparedEvent _ _ _ input _ cursor _ dispatch) ->
                      case dispatch of
                        Nothing -> block identity key [errorDiagnostic "flow.dispatch" "Pending event has no captured dispatch entry"]
                        Just (program,safety)
                          | Just state <- wait.adapter, state.dispatch == Started, safety == RequireExplicitRetry ->
                              block identity key [errorDiagnostic "flow.dispatch-uncertain"
                                "The provider may already have received this request. flow retry sends it again; confirm that repeating it is appropriate."]
                          | otherwise -> encodeValue (contractShape input) (toAeson request.payload) >>= \case
                              Left problems -> block identity key problems
                              Right _ -> do
                                -- This catalog transition rechecks openness and terminal state
                                -- immediately before the call, while adapter ownership is held.
                                started <- beginDispatch identity key
                                case started of
                                  Right True -> catchError @Failure.OperationalFailure
                                    (dispatchEvent program config (flowInstanceIdText identity <> ":" <> key) (toAeson request.payload) >>= \case
                                      Left problems -> block identity key problems
                                      Right value -> encodeValue (contractShape cursor) value >>= \case
                                        Left problems -> block identity key problems
                                        Right _ -> completeDispatch identity key value >>= \case
                                          Right () -> pure Advanced
                                          Left problem -> block identity key [errorDiagnostic "flow.dispatch" (show problem)])
                                    (\_ problem -> block identity key [Failure.operationalDiagnostic problem])
                                  Right False -> pure NoWork
                                  Left problem -> block identity key [errorDiagnostic "flow.dispatch" (show problem)]
                _ -> block identity key [errorDiagnostic "flow.dispatch" "Captured recipe is missing"]
            External -> pure NoWork
        _ -> pure NoWork
      _ -> pure NoWork
    block identity key problems = blockDispatch identity key problems >>= \case
      Left _ -> pure Blocked
      Right () -> pure Blocked
