{-# LANGUAGE OverloadedStrings, OverloadedRecordDot, TypeApplications #-}
module InteractiveBindingsTests (main) where

import Control.Monad (unless, forM_)
import qualified Agentic.Value as V
import Kyyn.Contract (compileContract, contract, CompiledContract(..), Codec(..))
import Kyyn.Types.EventWait (eventRequestCodec, decodeEventRequest, receivedReplyCodec)
import Data.Text (Text)
import Kyyn.Interactive
import Kyyn.Interactive.Internal (FlowDefinition(..))
import Kyyn.Interactive.Event (EventRef(..), eventRef)
import Kyyn.Plugin.Event (LiveEvent, EventPoll, EventBatch)
import Kyyn.Types.Plugin (ConnectorInstance(..), FetchError)
import Kyyn.Types.KnowledgeBase

main :: IO ()
main = do
  let base = FlowDefinition (FlowEntryRef "Flows.parent") (InteractionBindings [] [])
        (error "state must not be forced") (error "input must not be forced") (error "output must not be forced") :: FlowDefinition () ()
      reference = eventRef "fixture" "Updates" "question" poll (ConnectorInstance "updates" :: ConnectorInstance ())
      EventRef expected _ = reference
      childRef = child (RecipeId "child") base
      bindings (FlowDefinition _ selected _ _ _) = selected
      left = bindings (withChildren [childRef] (withEvents [event reference] base))
      right = bindings (withEvents [event reference] (withChildren [childRef] base))
  unless (left == right && left == InteractionBindings [ChildReference (RecipeId "child") (FlowEntryRef "Flows.parent")] [expected])
    (fail "Child and event declaration helpers do not preserve one another")
  unless (bindings (withEvents [] (withChildren [childRef] base)) == InteractionBindings [ChildReference (RecipeId "child") (FlowEntryRef "Flows.parent")] [])
    (fail "Replacing events cleared child declarations")
  compiled <- either (fail . show) pure (compileContract (contract @Text))
  receivedContract <- either (fail . show) pure (compileContract (contract @(ReceivedReply Text)))
  let requestCodec = eventRequestCodec expected compiled.description compiled.description compiled.codec
      replyCodec = receivedReplyCodec compiled.codec
      encoded = requestCodec.encode "Question"
      rejected value = case requestCodec.decode value of Left _ -> pure (); Right _ -> fail "Malformed event envelope accepted"
  unless (requestCodec.decode encoded == Right "Question") (fail "Event request failed roundtrip")
  case encoded of
    V.Object fields -> do
      rejected (V.Object (("extra",V.String "x"):fields))
      rejected (V.Object (("kyynWait",V.String "event"):fields))
      rejected (V.Object [(key,if key == "binding" then V.String "{}" else value) | (key,value) <- fields])
      rejected (V.Object [(key,if key == "payload" then V.Integer 4 else value) | (key,value) <- fields])
      case decodeEventRequest (V.Object [(key,if key == "kyynWait" then V.String "unknown" else value) | (key,value) <- fields]) of
        Left _ -> pure (); Right _ -> fail "Unknown event envelope accepted"
    _ -> fail "Event envelope is not an object"
  forM_ [ManualReply "cli",ProviderReply expected (EventIdentity "event-1")] $ \source -> do
    let reply = ReceivedReply source "Answer"
    unless (receivedContract.codec.encode reply == replyCodec.encode reply &&
      receivedContract.codec.decode (replyCodec.encode reply) == Right reply)
      (fail "ReceivedReply persistence and Contract encodings differ")
    unless (replyCodec.decode (replyCodec.encode reply) == Right reply) (fail "Reply provenance failed roundtrip")
  case replyCodec.decode (V.String "Answer") of
    Left _ -> pure (); Right _ -> fail "Unwrapped reply accepted"
  putStrLn "Event type witnesses stay unevaluated and declaration helpers compose."
  where
    poll :: () -> EventPoll Text Integer -> LiveEvent (Either FetchError (EventBatch Text Integer))
    poll = error "The poll type witness must not run during declaration"
