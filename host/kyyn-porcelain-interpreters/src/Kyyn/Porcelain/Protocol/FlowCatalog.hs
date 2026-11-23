{-# LANGUAGE OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Porcelain.Protocol.FlowCatalog (catalogValue, parseCatalog) where

import Kyyn.Types.EventIdentity (EventIdentity(..))
import Control.Monad (unless)
import Data.Aeson (Key, Value(..), object, toJSON, parseJSON, (.=), (.:), withObject)
import Data.Aeson.Types (Parser, Object)
import qualified Data.Aeson.KeyMap as Keys
import Data.List (nub, sort)
import qualified Data.Text as Text
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport(..))
import Kyyn.Plumbing.Protocol.Validation (diagnosticValue, parseReport)
import Kyyn.Domain.FlowBundleId (flowBundleId, flowBundleIdText)
import Kyyn.Domain.Recipe (recipeId)
import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Kyyn.Domain.RecipeRunId (recipeRunId, runIdText)
import Kyyn.Domain.FlowInstance

catalogValue :: [FlowInstance] -> Value
catalogValue = toList . map instanceValue
  where toList values = object ["instances" .= values]

instanceValue :: FlowInstance -> Value
instanceValue item = object
  ["id" .= flowInstanceIdText item.instanceId,"parent" .= fmap flowInstanceIdText item.parent
  ,"startKey" .= item.startKey,"launch" .= launchValue item.launch,"status" .= statusValue item.status
  ,"retryRequired" .= item.retryRequired,"blocked" .= map diagnosticValue item.blocked,"cancelDescendants" .= item.cancelDescendants
  ,"attempts" .= map runIdText item.attempts
  ,"waits" .= map waitValue item.waits,"deliveries" .= map deliveryValue item.deliveries]
launchValue :: FlowLaunch -> Value
launchValue item = object ["revision" .= item.revision,"request" .= item.request,
  "owner" .= case item.owner of
    Hosted bundle (RecipeId recipe) -> object ["tag" .= String "hosted","bundle" .= flowBundleIdText bundle,"recipe" .= recipe]
    External -> object ["tag" .= String "external"]]
statusValue :: ExecutionStatus -> Value
statusValue Runnable = tag "runnable" Null
statusValue Running = tag "running" Null
statusValue Waiting = tag "waiting" Null
statusValue (Finished outcome) = tag "finished" (case outcome of
  Completed value -> tag "completed" value
  Failed errors -> object ["tag" .= String "failed","value" .= map diagnosticValue errors]
  Cancelled -> tag "cancelled" Null)
waitValue :: FlowWait -> Value
waitValue wait = object ["id" .= wait.waitId,"descriptor" .= wait.descriptor,"kind" .= kindValue wait.kind,"dispatch" .= fmap dispatchValue wait.dispatch,"status" .= case wait.waitStatus of
  Open -> tag "open" Null
  Closed -> tag "closed" Null
  Answered origin value -> tag "answered" (object ["origin" .= originValue origin,"value" .= value])]
kindValue :: WaitKind -> Value
kindValue ReplyWait = tag "reply" Null
kindValue (ChildWait child output) = tag "child" (object ["child" .= flowInstanceIdText child,"outputContract" .= output])
kindValue (EventWait reference) = tag "event" (toJSON reference)
dispatchValue :: DispatchState -> Text.Text
dispatchValue NotRequired = "notRequired"
dispatchValue Pending = "pending"
dispatchValue Started = "started"
dispatchValue DispatchCompleted = "completed"
originValue :: DeliveryOrigin -> Value
originValue (ChildCompletion child) = tag "child" (String (flowInstanceIdText child))
originValue (ReceivedFrom (ManualReply surface)) = tag "manual" (String surface)
originValue (ReceivedFrom (ProviderReply binding (EventIdentity event))) = tag "provider" (object ["binding" .= binding,"event" .= event])
deliveryValue :: FlowDelivery -> Value
deliveryValue item = object ["id" .= item.deliveryId,"wait" .= item.waitId,"origin" .= originValue item.origin,
  "value" .= item.value,"outcome" .= fmap outcomeValue item.outcome]
outcomeValue :: DeliveryOutcome -> Value
outcomeValue outcome = case outcome of
  Accepted -> tag "accepted" Null
  Duplicate -> tag "duplicate" Null
  Conflicting -> tag "conflict" Null
  Invalid message -> tag "invalid" (String message)
  ClosedWait -> tag "closed" Null
tag :: Text.Text -> Value -> Value
tag name value = object ["tag" .= name,"value" .= value]

parseCatalog :: Value -> Parser [FlowInstance]
parseCatalog = withObject "flow catalog" $ \fields -> do
  exact ["instances"] fields
  catalog <- fields .: "instances" >>= traverse parseInstance
  unique "instance IDs" (map (.instanceId) catalog)
  unique "child start keys" [(item.parent,item.startKey) | item <- catalog]
  let ids = map (.instanceId) catalog
  mapM_ (\item -> maybe (pure ()) (\parent -> unless (parent `elem` ids) (fail "Missing flow parent")) item.parent) catalog
  mapM_ (acyclic catalog []) catalog
  pure catalog
  where
    acyclic catalog seen item = do
      unless (item.instanceId `notElem` seen) (fail "Cyclic flow parentage")
      case [parent | parent <- catalog, Just parent.instanceId == item.parent] of
        [] -> pure ()
        [parent] -> acyclic catalog (item.instanceId:seen) parent
        _ -> fail "Duplicate flow parent"
parseInstance :: Value -> Parser FlowInstance
parseInstance = withObject "instance" $ \fields -> do
  exact ["id","parent","startKey","launch","status","blocked","retryRequired","cancelDescendants","waits","deliveries","attempts"] fields
  identity <- fields .: "id" >>= checkedId
  parent <- fields .: "parent" >>= traverse checkedId
  waits <- fields .: "waits" >>= traverse parseWait
  deliveries <- fields .: "deliveries" >>= traverse parseDelivery
  attempts <- fields .: "attempts" >>= traverse (either fail pure . recipeRunId)
  unique "attempt IDs" attempts
  unique "wait IDs" (map (.waitId) waits)
  unique "delivery IDs" (map (.deliveryId) deliveries)
  FlowInstance identity parent <$> fields .: "startKey" <*> (fields .: "launch" >>= parseLaunch)
    <*> (fields .: "status" >>= parseStatus) <*> (fields .: "blocked" >>= diagnostics) <*> fields .: "retryRequired" <*> fields .: "cancelDescendants"
    <*> pure waits <*> pure deliveries <*> pure attempts
parseLaunch :: Value -> Parser FlowLaunch
parseLaunch = withObject "launch" $ \fields -> do
  exact ["revision","request","owner"] fields
  owner <- fields .: "owner" >>= withObject "execution owner" (\value -> do
    name <- value .: "tag"
    case name :: Text.Text of
      "hosted" -> do
        exact ["tag","bundle","recipe"] value
        Hosted <$> (value .: "bundle" >>= either fail pure . flowBundleId)
          <*> (value .: "recipe" >>= either fail pure . recipeId)
      "external" -> exact ["tag"] value >> pure External
      _ -> fail "Unknown execution owner")
  FlowLaunch <$> fields .: "revision" <*> fields .: "request" <*> pure owner
parseStatus :: Value -> Parser ExecutionStatus
parseStatus value = tagged value >>= \(name,payload) -> case (name,payload) of
  ("runnable",Null) -> pure Runnable
  ("running",Null) -> pure Running
  ("waiting",Null) -> pure Waiting
  ("finished",body) -> Finished <$> (tagged body >>= \(outcome,result) -> case (outcome,result) of
    ("completed",v) -> pure (Completed v)
    ("failed",v) -> Failed <$> diagnostics v
    ("cancelled",Null) -> pure Cancelled
    _ -> fail "Invalid flow outcome")
  _ -> fail "Invalid execution status"
parseWait :: Value -> Parser FlowWait
parseWait = withObject "wait" $ \fields -> do
  exact ["id","descriptor","kind","status","dispatch"] fields
  state <- fields .: "status" >>= tagged >>= \(name,payload) -> case (name,payload) of
    ("open",Null) -> pure Open
    ("closed",Null) -> pure Closed
    ("answered",body) -> withObject "reply" (\reply -> do
      exact ["origin","value"] reply
      Answered <$> (reply .: "origin" >>= parseOrigin) <*> reply .: "value") body
    _ -> fail "Invalid wait status"
  kind <- fields .: "kind" >>= parseKind
  dispatch <- fields .: "dispatch" >>= traverse (\name -> case name :: Text.Text of
    "notRequired" -> pure NotRequired; "pending" -> pure Pending
    "started" -> pure Started; "completed" -> pure DispatchCompleted
    _ -> fail "Invalid dispatch state")
  unless (case kind of EventWait{} -> dispatch /= Nothing; _ -> dispatch == Nothing)
    (fail "Dispatch state must belong to an event wait")
  FlowWait <$> fields .: "id" <*> fields .: "descriptor" <*> pure kind <*> pure state <*> pure dispatch
parseKind :: Value -> Parser WaitKind
parseKind value = tagged value >>= \(name,payload) -> case (name,payload) of
  ("reply",Null) -> pure ReplyWait
  ("child",body) -> withObject "child wait" (\fields -> do
    exact ["child","outputContract"] fields
    ChildWait <$> (fields .: "child" >>= checkedId) <*> fields .: "outputContract") body
  ("event",body) -> EventWait <$> parseJSON body
  _ -> fail "Invalid wait kind"
parseOrigin :: Value -> Parser DeliveryOrigin
parseOrigin value = tagged value >>= \(name,payload) -> case (name,payload) of
  ("child",String child) -> ChildCompletion <$> checkedId child
  ("manual",String surface) -> pure (ReceivedFrom (ManualReply surface))
  ("provider",body) -> withObject "provider origin" (\fields -> do
    exact ["binding","event"] fields
    ReceivedFrom <$> (ProviderReply <$> fields .: "binding" <*> (EventIdentity <$> fields .: "event"))) body
  _ -> fail "Invalid reply origin"
parseDelivery :: Value -> Parser FlowDelivery
parseDelivery = withObject "delivery" $ \fields -> do
  exact ["id","wait","origin","value","outcome"] fields
  FlowDelivery <$> fields .: "id" <*> fields .: "wait" <*> (fields .: "origin" >>= parseOrigin)
    <*> fields .: "value" <*> (fields .: "outcome" >>= traverse parseOutcome)
parseOutcome :: Value -> Parser DeliveryOutcome
parseOutcome value = tagged value >>= \(name,payload) -> case (name,payload) of
  ("accepted",Null) -> pure Accepted
  ("duplicate",Null) -> pure Duplicate
  ("conflict",Null) -> pure Conflicting
  ("invalid",String message) -> pure (Invalid message)
  ("closed",Null) -> pure ClosedWait
  _ -> fail "Invalid delivery outcome"
tagged :: Value -> Parser (Text.Text,Value)
tagged = withObject "variant" $ \fields -> exact ["tag","value"] fields >> ((,) <$> fields .: "tag" <*> fields .: "value")
checkedId :: Text.Text -> Parser FlowInstanceId
checkedId = either fail pure . flowInstanceId
exact :: [Key] -> Object -> Parser ()
exact expected fields = unless (sort (Keys.keys fields) == sort expected) (fail "Unexpected flow catalog fields")
unique :: Eq a => String -> [a] -> Parser ()
unique label values = unless (length (nub values) == length values) (fail ("Duplicate " ++ label))

diagnostics :: Value -> Parser [Diagnostic]
diagnostics value = do
  ValidationReport items <- parseReport value
  pure items
