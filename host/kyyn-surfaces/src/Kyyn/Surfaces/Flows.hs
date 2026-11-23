{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Surfaces.Flows (FlowValues(..), waitLabel, instanceValue, instanceLines, deliveryValue, deliveryOutcomeText, statusText) where

import qualified Data.Aeson.KeyMap as Keys
import Data.Foldable (toList)
import Data.Aeson (Value(..), object, (.=), encode)
import qualified Data.ByteString.Lazy as Bytes
import qualified Data.Text.Encoding as Text
import qualified Data.Text as Text
import Kyyn.Domain.FlowInstance
import Kyyn.Domain.FlowBundleId (flowBundleIdText)
import Kyyn.Domain.RecipeRunId (runIdText)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Types.KnowledgeBase (RecipeId(..))

data FlowValues = FlowValues
  { input :: Maybe Text.Text, output :: Maybe Text.Text, diagnostics :: [Diagnostic] }

-- Upstream path notes are outermost first. Keep transport IDs separate from
-- the authored name, since the durable key is deliberately not a display label.
waitLabel :: Int -> [(Text.Text,Value)] -> FlowWait -> Text.Text
waitLabel index descriptors wait = case reverse names of
  name:_ -> name
  [] -> "Wait " <> Text.pack (show index)
  where
    names = [name | Just (Object descriptor) <- [lookup wait.waitId descriptors],
      Just (Array path) <- [Keys.lookup "path" descriptor], Object note <- toList path,
      Just (String name) <- [Keys.lookup "name" note], not (Text.null (Text.strip name))]

-- Pending descriptors here are upstream's decoded plain-data descriptions,
-- supplied by the application boundary without loading the guest executable.
instanceValue :: FlowInstance -> Bool -> [(Text.Text,Value)] -> Maybe Text.Text -> Maybe Text.Text -> [Diagnostic] -> Value
instanceValue item interrupted descriptors input result problems = object
  ["id" .= flowInstanceIdText item.instanceId,"parent" .= fmap flowInstanceIdText item.parent,
   "status" .= statusText item interrupted,"retryRequired" .= item.retryRequired,
   "revision" .= item.launch.revision,"input" .= input,
   "inspectionDiagnostics" .= [object ["code" .= problem.code,"message" .= problem.message] | problem <- problems],
   "owner" .= case item.launch.owner of
      External -> object ["kind" .= String "external"]
      Hosted bundle (RecipeId name) -> object ["kind" .= String "hosted","recipe" .= name,"bundle" .= flowBundleIdText bundle],
   "failure" .= [object ["code" .= problem.code,"message" .= problem.message] | Finished (Failed failures) <- [item.status], problem <- failures],
   "blocked" .= [object ["code" .= problem.code,"message" .= problem.message] | problem <- item.blocked],
   "waits" .= [object ["id" .= wait.waitId,"status" .= waitStatusText wait.waitStatus,
      "descriptor" .= (case wait.kind of ReplyWait -> lookup wait.waitId descriptors; ChildWait{} -> Nothing),
      "child" .= (case wait.kind of ChildWait child _ -> Just (flowInstanceIdText child); ReplyWait -> Nothing),"reply" .= case wait.waitStatus of
        Answered origin value -> Just (object ["origin" .= originValue origin,"value" .= value]); _ -> Nothing]
      | wait <- item.waits],
   "deliveries" .= map deliveryValue item.deliveries,
   "attempts" .= [object ["id" .= runIdText ident,"path" .= ("/runs/" ++ runIdText ident)] | ident <- item.attempts],
   "result" .= result]

instanceLines :: FlowInstance -> Bool -> [(Text.Text,Value)] -> Maybe Text.Text -> Maybe Text.Text -> [Diagnostic] -> [String]
instanceLines item interrupted descriptors input result problems =
  [Text.unpack (flowInstanceIdText item.instanceId) ++ "  " ++ Text.unpack (statusText item interrupted)] ++
  maybe [] (\value -> ["Input: " ++ Text.unpack value]) input ++
  maybe [] (\value -> ["Result: " ++ Text.unpack value]) result ++
  ["Inspection: " ++ Text.unpack problem.message | problem <- problems] ++
  ["Failed: " ++ Text.unpack problem.message | Finished (Failed failures) <- [item.status], problem <- failures] ++
  ["Blocked: " ++ Text.unpack diagnostic.message | diagnostic <- item.blocked] ++
  [Text.unpack (waitLabel index descriptors wait) ++ " [" ++ Text.unpack wait.waitId ++ "]  " ++ Text.unpack (waitStatusText wait.waitStatus) ++ (case wait.kind of ChildWait child _ -> " on child " ++ Text.unpack (flowInstanceIdText child); ReplyWait -> "") | (index,wait) <- zip [1..] item.waits] ++
  ["Wait description " ++ Text.unpack identity ++ ": " ++ Text.unpack (Text.decodeUtf8 (Bytes.toStrict (encode value))) | (identity,value) <- descriptors, any (\wait -> wait.waitId == identity && wait.kind == ReplyWait) item.waits] ++
  ["Reply " ++ Text.unpack wait.waitId ++ ": " ++ Text.unpack (Text.decodeUtf8 (Bytes.toStrict (encode value))) | wait <- item.waits, Answered _ value <- [wait.waitStatus]] ++
  ["Attempt " ++ runIdText ident ++ ": /runs/" ++ runIdText ident | ident <- item.attempts]

statusText :: FlowInstance -> Bool -> Text.Text
statusText item interrupted = case item.status of
  Runnable -> "runnable"
  Running -> if interrupted then "interrupted" else "running"
  Waiting -> "waiting"
  Finished (Completed _) -> "completed"
  Finished (Failed _) -> "failed"
  Finished Cancelled -> "cancelled"

waitStatusText :: WaitStatus -> Text.Text
waitStatusText Open = "open"
waitStatusText Answered{} = "answered"
waitStatusText Closed = "closed"

originValue :: ReplyOrigin -> Value
originValue (ChildCompletion child) = object ["kind" .= String "child","child" .= flowInstanceIdText child]
originValue (ManualReply surface) = object ["kind" .= String "manual","surface" .= surface]
originValue (ProviderReply binding event) = object ["kind" .= String "provider","binding" .= binding,"event" .= event]

deliveryValue :: FlowDelivery -> Value
deliveryValue delivery = object ["id" .= delivery.deliveryId,"wait" .= delivery.waitId,
  "origin" .= originValue delivery.origin,"outcome" .= maybe "queued" deliveryOutcomeText delivery.outcome,
  "reason" .= case delivery.outcome of Just (Invalid reason) -> Just reason; _ -> Nothing]

deliveryOutcomeText :: DeliveryOutcome -> Text.Text
deliveryOutcomeText Accepted = "accepted"
deliveryOutcomeText Duplicate = "duplicate"
deliveryOutcomeText Conflicting = "conflicting"
deliveryOutcomeText (Invalid _) = "invalid"
deliveryOutcomeText ClosedWait = "closed"
