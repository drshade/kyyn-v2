{-# LANGUAGE OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Domain.FlowPolling (pollDue, beginPoll, failPoll, completePoll) where

import Control.Monad (foldM)
import Data.Aeson (Value)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, addUTCTime)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FlowInstance
import Kyyn.Types.Plugin (Seconds(..))
import Kyyn.Types.EventIdentity (EventIdentity)

pollDue :: UTCTime -> FlowWait -> Bool
pollDue now wait = wait.waitStatus == Open && case wait.adapter of
  Just state -> null state.dispatchProblems && state.dispatch `elem` [NotRequired,DispatchCompleted]
    && maybe True (<= now) state.polling.nextAttempt
  Nothing -> False

beginPoll :: UTCTime -> Seconds -> Text -> FlowInstance -> Either FlowStoreProblem (Bool,FlowInstance)
beginPoll now (Seconds interval) key current
  | Finished{} <- current.status = Right (False,current)
  | current.retryRequired = Right (False,current)
  | otherwise = case find ((== key) . (.waitId)) current.waits of
      Just wait | pollDue now wait -> do
        updated <- change key (\state -> state {polling = state.polling
          {lastAttempt = Just now, nextAttempt = Just (addUTCTime (fromInteger interval) now)}}) current
        pure (True,updated)
      _ -> Right (False,current)

failPoll :: Text -> [Diagnostic] -> FlowInstance -> Either FlowStoreProblem FlowInstance
failPoll key diagnostics = change key (\state -> state {polling = state.polling
  {consecutiveFailures = state.polling.consecutiveFailures + 1, problems = diagnostics}})

-- Every payload is validated before this transaction. Repeated provider events
-- are deduplicated per bound wait; conflicting reuse is retained, never applied.
-- The adapter owner holds its lock through this entire result commit.
completePoll :: Text -> [(EventIdentity,Value)] -> Value -> FlowInstance
  -> Either FlowStoreProblem (Bool,FlowInstance)
completePoll key arrivals cursor current = do
  reference <- case find ((== key) . (.waitId)) current.waits of
    Just wait | EventWait ref <- wait.kind, Just state <- wait.adapter,
      state.dispatch `elem` [NotRequired,DispatchCompleted], state.polling.lastAttempt /= Nothing -> Right ref
    _ -> Left (InvalidTransition "Missing event wait")
  let append (queued,item) (event,value) =
        let origin = ReceivedFrom (ProviderReply reference event)
            previous = [delivery | delivery <- item.deliveries, delivery.waitId == key, delivery.origin == origin]
            terminal = case item.status of Finished{} -> True; _ -> False
            closed = terminal || maybe True ((== Closed) . (.waitStatus)) (find ((== key) . (.waitId)) item.waits)
            outcome | closed = Just ClosedWait
                    | not (null previous) = Just Conflicting
                    | Just wait <- find ((== key) . (.waitId)) item.waits,
                      Answered _ accepted <- wait.waitStatus = Just (if accepted == value then Duplicate else Conflicting)
                    | otherwise = Nothing
            fresh = freshAt (length item.deliveries)
            freshAt n = let candidate = "internal-event-" <> Text.pack (show n)
              in if any ((== candidate) . (.deliveryId)) item.deliveries then freshAt (n + 1) else candidate
        in if any ((== value) . (.value)) previous then Right (queued,item)
           else Right (queued || outcome == Nothing,item {deliveries = item.deliveries ++ [FlowDelivery fresh key origin value outcome]})
  (queued,received) <- foldM append (False,current) arrivals
  updated <- change key (\state -> state {cursor = Just cursor, polling = state.polling {consecutiveFailures = 0,problems = []}}) received
  pure (queued,updated)

change :: Text -> (EventAdapter -> EventAdapter) -> FlowInstance -> Either FlowStoreProblem FlowInstance
change key update current = case find ((== key) . (.waitId)) current.waits of
  Just wait | Just _ <- wait.adapter -> Right current
    {waits = [if old.waitId == key then old {adapter = fmap update old.adapter} else old | old <- current.waits]}
  _ -> Left (InvalidTransition "Missing event wait")
