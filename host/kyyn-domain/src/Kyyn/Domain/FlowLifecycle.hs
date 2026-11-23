{-# LANGUAGE DuplicateRecordFields, OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Domain.FlowLifecycle
  ( begin, frontier, finish, block, cancelTree, enqueue, resolve, parentAllowsStart, clearFinished ) where

import Control.Monad (unless)
import Data.Aeson (Value)
import Data.List (find, nub)
import Data.Text (Text)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FlowInstance

begin :: FlowInstance -> Either FlowStoreProblem FlowInstance
begin current
  | current.launch.owner /= Hosted = Left NotHosted
  | not (null current.blocked) = Left ExecutionBlocked
  | Finished{} <- current.status = Left AlreadyFinished
  | otherwise = Right current { status = Running }

-- A successful frontier is authoritative; a failed attempt never calls this.
frontier :: [(Text,Value)] -> FlowInstance -> Either FlowStoreProblem FlowInstance
frontier reached current = do
  unless (current.status == Running) (Left (InvalidTransition "Frontier requires a running attempt"))
  unless (length (nub (map fst reached)) == length reached && not (null reached))
    (Left (InvalidTransition "Waiting frontier must be nonempty with unique wait IDs"))
  new <- traverse attach reached
  let close old = if old.waitId `elem` map fst reached then old else closeWait old
      retained = [close old | old <- current.waits, old.waitId `notElem` map fst reached]
  pure current { status = Waiting, waits = retained ++ new }
  where
    attach (identity,description) = case find ((== identity) . (.waitId)) current.waits of
      Nothing -> Right (FlowWait identity description Open)
      Just old | old.descriptor /= description -> Left (InvalidTransition "Wait descriptor changed")
               | old.waitStatus /= Open -> Left (InvalidTransition "Reported wait is already closed or answered")
               | otherwise -> Right old

finish :: FlowOutcome -> FlowInstance -> Either FlowStoreProblem FlowInstance
finish outcome current = case current.status of
  Finished old | old == outcome -> Right current
               | otherwise -> Left AlreadyFinished
  _ -> Right current { status = Finished outcome, waits = map closeWait current.waits }

block :: [Diagnostic] -> FlowInstance -> Either FlowStoreProblem FlowInstance
block problems current = case current.status of
  Finished{} -> Left AlreadyFinished
  _ -> Right current { blocked = problems }

parentAllowsStart :: Maybe FlowInstanceId -> [FlowInstance] -> Either FlowStoreProblem ()
parentAllowsStart Nothing _ = Right ()
parentAllowsStart (Just identity) catalog = do
  current <- maybe (Left MissingInstance) Right (find ((== identity) . (.instanceId)) catalog)
  unless (not current.cancelDescendants) (Left CancelledAncestor)
  case current.status of
    Finished{} -> Left AlreadyFinished
    _ -> ancestors current.parent
  where
    ancestors Nothing = Right ()
    ancestors (Just parent) = do
      item <- maybe (Left MissingInstance) Right (find ((== parent) . (.instanceId)) catalog)
      if item.cancelDescendants then Left CancelledAncestor else ancestors item.parent

cancelTree :: FlowInstanceId -> CancelScope -> [FlowInstance] -> Either FlowStoreProblem [FlowInstance]
cancelTree identity scope catalog = do
  unless (any ((== identity) . (.instanceId)) catalog) (Left MissingInstance)
  pure (map cancel catalog)
  where
    selected item = item.instanceId == identity || scope == FlowAndDescendants && descendant item.parent
    descendant Nothing = False
    descendant (Just parent)
      | parent == identity = True
      | otherwise = maybe False (descendant . (.parent)) (find ((== parent) . (.instanceId)) catalog)
    cancel item
      | not (selected item) = item
      | otherwise = item
          { status = case item.status of Finished old -> Finished old; _ -> Finished Cancelled
          , cancelDescendants = item.cancelDescendants || scope == FlowAndDescendants
          , waits = map closeWait item.waits
          }

-- The delivery identity is supplied by ingress (provider event ID or fresh manual ID).
-- Queuing is not fulfilment; terminal and unknown waits are retained as closed deliveries.
enqueue :: Text -> Text -> ReplyOrigin -> Value -> FlowInstance
  -> Either FlowStoreProblem (FlowInstance,FlowDelivery)
enqueue delivery wait origin value current = case find ((== delivery) . (.deliveryId)) current.deliveries of
  Just old | old.waitId == wait && old.origin == origin && old.value == value -> Right (current,old)
           | otherwise -> Left (InvalidTransition "Delivery identity already has different contents")
  Nothing ->
    let terminal = case current.status of Finished{} -> True; _ -> False
        wanted = maybe False ((/= Closed) . (.waitStatus)) (find ((== wait) . (.waitId)) current.waits)
        item = FlowDelivery delivery wait origin value (if terminal || not wanted then Just ClosedWait else Nothing)
    in Right (current { deliveries = current.deliveries ++ [item] },item)

-- Only the worker calls this after actual guest codec validation under the writer
-- lock. Recheck cancellation here: it can race with that validation.
resolve :: Text -> DeliveryOutcome -> FlowInstance -> Either FlowStoreProblem FlowInstance
resolve identity outcome current = do
  item <- maybe (Left (InvalidTransition "Missing delivery")) Right
    (find ((== identity) . (.deliveryId)) current.deliveries)
  case item.outcome of
    Just old | old == outcome -> Right current
             | otherwise -> Left (InvalidTransition "Delivery already resolved")
    Nothing -> do
      let found = find ((== item.waitId) . (.waitId)) current.waits
          terminal = case current.status of Finished{} -> True; _ -> False
          successful = outcome == Accepted || outcome == Duplicate
          actual = case (terminal,found) of
            (True,_) -> ClosedWait
            (_,Nothing) -> ClosedWait
            (_,Just wait) -> case wait.waitStatus of
              Closed -> ClosedWait
              Open -> if successful then Accepted else outcome
              Answered _ value
                | successful -> if value == item.value then Duplicate else Conflicting
                | otherwise -> outcome
          answer wait = if actual == Accepted && wait.waitId == item.waitId
            then wait { waitStatus = Answered item.origin item.value } else wait
          recorded delivery = if delivery.deliveryId == identity then delivery { outcome = Just actual } else delivery
      pure current
        { status = if actual == Accepted then Runnable else current.status
        , waits = map answer current.waits, deliveries = map recorded current.deliveries }

closeWait :: FlowWait -> FlowWait
closeWait wait = case wait.waitStatus of Open -> wait { waitStatus = Closed }; _ -> wait

-- Explicit clearing never removes a parent while a retained child names it.
-- Missing IDs are already cleared, making cleanup retries idempotent.
clearFinished :: [FlowInstanceId] -> [FlowInstance]
  -> Either FlowStoreProblem ([FlowInstanceId],[FlowInstance])
clearFinished requested catalog = do
  let removed = [item | item <- catalog, item.instanceId `elem` requested]
      remaining = [item | item <- catalog, item.instanceId `notElem` requested]
      ids = map (.instanceId) removed
  unless (all (\item -> case item.status of Finished{} -> True; _ -> False) removed)
    (Left (InvalidTransition "Only finished instances can be cleared"))
  unless (all (\item -> maybe True (`notElem` ids) item.parent) remaining)
    (Left (InvalidTransition "Clear an instance together with its finished descendants, or clear its children first"))
  pure (ids,remaining)
