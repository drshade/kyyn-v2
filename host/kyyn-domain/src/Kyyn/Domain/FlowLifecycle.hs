{-# LANGUAGE DuplicateRecordFields, OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Domain.FlowLifecycle
  ( deliverCompletions, requireDescendant, begin, frontier, finish, block, cancelTree, enqueue, resolve, parentAllowsStart, clearFinished, blockAttempt, retry ) where

import Control.Monad (unless, foldM)
import Data.Aeson (Value)
import Data.List (find, nub)
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FlowInstance

begin :: FlowInstance -> Either FlowStoreProblem FlowInstance
begin current
  | current.launch.owner == External = Left NotHosted
  | current.retryRequired || not (null current.blocked) = Left ExecutionBlocked
  | Finished{} <- current.status = Left AlreadyFinished
  | otherwise = Right current { status = Running }

-- A successful frontier is authoritative; a failed attempt never calls this.
frontier :: [(Text,Value,WaitKind,Maybe DispatchState)] -> FlowInstance -> Either FlowStoreProblem FlowInstance
frontier _ current | Finished{} <- current.status = Left AlreadyFinished
frontier reached current = do
  unless (current.status == Running) (Left (InvalidTransition "Frontier requires a running attempt"))
  unless (length (nub ([identity | (identity,_,_,_) <- reached])) == length reached && not (null reached))
    (Left (InvalidTransition "Waiting frontier must be nonempty with unique wait IDs"))
  new <- traverse attach reached
  let close old = if old.waitId `elem` [identity | (identity,_,_,_) <- reached] then old else closeWait old
      retained = [close old | old <- current.waits, old.waitId `notElem` [identity | (identity,_,_,_) <- reached]]
  pure current { status = Waiting, waits = retained ++ new }
  where
    attach (identity,description,kind,initialDispatch) = do
      unless (case kind of EventWait{} -> initialDispatch /= Nothing; _ -> initialDispatch == Nothing)
        (Left (InvalidTransition "Dispatch state must belong to an event wait"))
      case find ((== identity) . (.waitId)) current.waits of
        Nothing -> Right (FlowWait identity description kind Open (fmap (\phase -> EventAdapter phase Nothing [] initialPollState) initialDispatch))
        Just old | old.descriptor /= description || old.kind /= kind -> Left (InvalidTransition "Wait descriptor changed")
                 | old.waitStatus /= Open -> Left (InvalidTransition "Reported wait is already closed or answered")
                 | otherwise -> Right old

finish :: FlowOutcome -> FlowInstance -> Either FlowStoreProblem FlowInstance
finish outcome current = case current.status of
  Finished old | old == outcome -> Right current
               | otherwise -> Left AlreadyFinished
  _ -> Right current { status = Finished outcome, waits = map closeWait current.waits }

block :: [Diagnostic] -> FlowInstance -> Either FlowStoreProblem FlowInstance
block _ current | current.retryRequired = Left ExecutionBlocked
block problems current = case current.status of
  Finished{} -> Left AlreadyFinished
  _ -> Right current { blocked = problems }

-- Reported attempt failures require an explicit author/operator retry. Polling
-- can revalidate unavailable prerequisites but cannot repeat uncertain actions.
blockAttempt :: [Diagnostic] -> FlowInstance -> Either FlowStoreProblem FlowInstance
blockAttempt problems current = case current.status of
  Finished{} -> Left AlreadyFinished
  _ -> Right current { blocked = problems, retryRequired = True }

retry :: FlowInstance -> Either FlowStoreProblem FlowInstance
retry current = case current.status of
  Finished{} -> Left AlreadyFinished
  _ -> Right current { blocked = [], retryRequired = False, waits = map reset current.waits }
  where
    reset wait = wait { adapter = fmap (\state -> state
      { dispatchProblems = [], dispatch = case state.dispatch of
          Started | not (null state.dispatchProblems) -> Pending
          other -> other }) wait.adapter }

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
enqueue :: Text -> Text -> DeliveryOrigin -> Value -> FlowInstance
  -> Either FlowStoreProblem (FlowInstance,FlowDelivery)
enqueue delivery wait origin value current = do
  case (find ((== wait) . (.waitId)) current.waits,origin) of
    (Just selected,ChildCompletion child) | ChildWait expected _ <- selected.kind, child == expected -> Right ()
    (Just selected,_) | ChildWait{} <- selected.kind -> Left (InvalidTransition "Child waits can only receive the recorded child outcome; manual and provider replies are refused")
    (_,ChildCompletion _) -> Left (InvalidTransition "A child outcome requires its matching child wait")
    _ -> Right ()
  unless (case origin of ChildCompletion _ -> True; _ -> not ("internal-" `Text.isPrefixOf` delivery))
    (Left (InvalidTransition "Delivery keys beginning internal- are reserved"))
  receive
  where
   receive = case find ((== delivery) . (.deliveryId)) current.deliveries of
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

-- Run inside the same catalog commit as frontier publication or a terminal
-- transition. Internal keys cannot be supplied by ingress, so an unrelated
-- caller-key conflict cannot veto a child's terminal transition. The first
-- terminal outcome is immutable, making repeated publication idempotent.
deliverCompletions :: (FlowOutcome -> Value) -> [FlowInstance] -> Either FlowStoreProblem [FlowInstance]
deliverCompletions encode catalog = traverse notify catalog
  where
    notify item = foldM attach item [wait | wait <- item.waits, wait.waitStatus == Open]
    attach item wait = case wait.kind of
      ReplyWait -> Right item
      EventWait{} -> Right item
      ChildWait child _ -> case find ((== child) . (.instanceId)) catalog of
        Just selected | Finished outcome <- selected.status ->
          fst <$> enqueue ("internal-child-" <> wait.waitId) wait.waitId (ChildCompletion child) (encode outcome) item
        _ -> Right item

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
  unless (all (ancestorsFinished . (.parent)) removed)
    (Left (InvalidTransition "Cannot clear an instance beneath an unfinished ancestor; finish or cancel the ancestor first"))
  pure (ids,remaining)
  where
    ancestorsFinished Nothing = True
    ancestorsFinished (Just identity) = case find ((== identity) . (.instanceId)) catalog of
      Nothing -> True
      Just ancestor -> case ancestor.status of
        Finished{} -> ancestorsFinished ancestor.parent
        _ -> False

-- Resolve from one catalog snapshot. A missing/cleared target is different from
-- a present handle outside the caller's downward authority.
requireDescendant :: FlowInstanceId -> FlowInstanceId -> [FlowInstance] -> Either FlowStoreProblem FlowInstance
requireDescendant caller target catalog = do
  selected <- maybe (Left MissingInstance) Right (find ((== target) . (.instanceId)) catalog)
  _ <- maybe (Left MissingInstance) Right (find ((== caller) . (.instanceId)) catalog)
  unless (caller /= target && below selected.parent)
    (Left (InvalidTransition "Child control requires a strict descendant of the calling instance"))
  pure selected
  where
    below Nothing = False
    below (Just parent)
      | parent == caller = True
      | otherwise = maybe False (below . (.parent)) (find ((== parent) . (.instanceId)) catalog)
