{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Surfaces.Flows (instanceValue, instanceLines, deliveryValue, statusText) where

import Data.Aeson (Value(..), object, (.=))
import qualified Data.Text as Text
import Kyyn.Domain.FlowInstance
import Kyyn.Domain.FlowBundleId (flowBundleIdText)
import Kyyn.Domain.RecipeRunId (runIdText)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Types.KnowledgeBase (RecipeId(..))

-- Pending descriptors here are upstream's decoded plain-data descriptions,
-- supplied by the application boundary without loading the guest executable.
instanceValue :: FlowInstance -> Bool -> [(Text.Text,Value)] -> Value
instanceValue item interrupted descriptors = object
  ["id" .= flowInstanceIdText item.instanceId,"parent" .= fmap flowInstanceIdText item.parent,
   "status" .= statusText item interrupted,"retryRequired" .= item.retryRequired,
   "revision" .= item.launch.revision,"input" .= item.launch.request,
   "owner" .= case item.launch.owner of
      External -> object ["kind" .= String "external"]
      Hosted bundle (RecipeId name) -> object ["kind" .= String "hosted","recipe" .= name,"bundle" .= flowBundleIdText bundle],
   "failure" .= [object ["code" .= problem.code,"message" .= problem.message] | Finished (Failed problems) <- [item.status], problem <- problems],
   "blocked" .= [object ["code" .= problem.code,"message" .= problem.message] | problem <- item.blocked],
   "waits" .= [object ["id" .= wait.waitId,"status" .= waitStatusText wait.waitStatus,
      "descriptor" .= lookup wait.waitId descriptors,"reply" .= case wait.waitStatus of
        Answered origin value -> Just (object ["origin" .= originValue origin,"value" .= value]); _ -> Nothing]
      | wait <- item.waits],
   "deliveries" .= map deliveryValue item.deliveries,
   "attempts" .= [object ["id" .= runIdText ident,"path" .= ("/runs/" ++ runIdText ident)] | ident <- item.attempts],
   "result" .= case item.status of Finished (Completed result) -> Just result; _ -> Nothing]

instanceLines :: FlowInstance -> Bool -> [String]
instanceLines item interrupted =
  [Text.unpack (flowInstanceIdText item.instanceId) ++ "  " ++ Text.unpack (statusText item interrupted)] ++
  ["Failed: " ++ Text.unpack problem.message | Finished (Failed problems) <- [item.status], problem <- problems] ++
  ["Blocked: " ++ Text.unpack diagnostic.message | diagnostic <- item.blocked] ++
  ["Wait " ++ Text.unpack wait.waitId ++ "  " ++ Text.unpack (waitStatusText wait.waitStatus) | wait <- item.waits] ++
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
originValue (ManualReply surface) = object ["kind" .= String "manual","surface" .= surface]
originValue (ProviderReply binding event) = object ["kind" .= String "provider","binding" .= binding,"event" .= event]

deliveryValue :: FlowDelivery -> Value
deliveryValue delivery = object ["id" .= delivery.deliveryId,"wait" .= delivery.waitId,
  "origin" .= originValue delivery.origin,"outcome" .= case delivery.outcome of
    Nothing -> String "queued"
    Just Accepted -> String "accepted"
    Just Duplicate -> String "duplicate"
    Just Conflicting -> String "conflicting"
    Just (Invalid reason) -> object ["invalid" .= reason]
    Just ClosedWait -> String "closed"]
