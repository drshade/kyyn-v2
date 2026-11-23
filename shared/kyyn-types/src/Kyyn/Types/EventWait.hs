{-# LANGUAGE NoFieldSelectors, DeriveGeneric, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Types.EventWait
  ( ReplyOrigin(..), ReceivedReply(..), receivedReplyCodec, encodeReceivedReply
  , EventWaitRequest(..), eventRequestCodec, encodeEventRequest, decodeEventRequest ) where

import Agentic.Contract (Contract(..), Structure(..), Fields(..), Case(..), Constructor(..), FieldStyle(..), nominal)
import Agentic.Codec (Codec(..))
import qualified Agentic.Schema as S
import Agentic.Value (Value(..))
import Control.Monad (unless)
import Data.Aeson (encode, eitherDecodeStrict', ToJSON, FromJSON)
import qualified Data.ByteString.Lazy as Bytes
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Type.Reflection (Typeable)
import GHC.Generics (Generic)
import Kyyn.Types.Contract (Description)
import Kyyn.Types.KnowledgeBase (EventReference(..))
import Kyyn.Types.EventIdentity (EventIdentity(..))

-- Ingress supplies provenance; a submitted reply never chooses it.
data ReplyOrigin = ManualReply Text | ProviderReply { providerBinding :: EventReference, eventIdentity :: EventIdentity } deriving (Eq, Show, Generic)
instance Contract ReplyOrigin where
  contract = nominal (Sum
    [ Case (Constructor "manual" PositionalFields) Nothing
        (\source -> case source of ManualReply surface -> Just surface; _ -> Nothing)
        ManualReply (Field "value" Nothing contract id)
    , Case (Constructor "provider" RecordFields) Nothing
        (\source -> case source of ProviderReply binding identity -> Just (binding,identity); _ -> Nothing)
        (uncurry ProviderReply)
        ((,) <$> Field "binding" Nothing contract fst <*> Field "event" Nothing contract snd)
    ])

data ReceivedReply reply = ReceivedReply { origin :: ReplyOrigin, value :: reply }
  deriving (Eq, Show, Generic)
instance (Contract reply, Typeable reply) => Contract (ReceivedReply reply)

data EventWaitRequest = EventWaitRequest
  { binding :: EventReference, requestContract :: Description, replyContract :: Description, payload :: Value }
  deriving (Eq, Show)

-- The identity and both contracts are fixed by the generated EventRef. Decoding
-- rechecks them on replay rather than allowing journal data to select a binding.
eventRequestCodec :: EventReference -> Description -> Description -> Codec a -> Codec a
eventRequestCodec ref input output codec = Codec schema
  (encodeEventRequest . EventWaitRequest ref input output . codec.encode) decode
  where
    schema = recordSchema [("kyynWait",textSchema),("binding",textSchema),
      ("requestContract",textSchema),("replyContract",textSchema),("payload",codec.schema)]
    decode encoded = do
      request <- decodeEventRequest encoded
      unless (request.binding == ref && request.requestContract == input && request.replyContract == output)
        (Left "Event wait binding or contracts differ from the captured reference")
      codec.decode request.payload

encodeEventRequest :: EventWaitRequest -> Value
encodeEventRequest request = Object
  [("kyynWait",String "event"),("binding",json request.binding),
   ("requestContract",json request.requestContract),("replyContract",json request.replyContract),("payload",request.payload)]

decodeEventRequest :: Value -> Either Text EventWaitRequest
decodeEventRequest value = do
  fields <- record ["kyynWait","binding","requestContract","replyContract","payload"] value
  unless (lookup "kyynWait" fields == Just (String "event")) (Left "Invalid event wait kind")
  EventWaitRequest <$> (field "binding" fields >>= fromJson)
    <*> (field "requestContract" fields >>= fromJson) <*> (field "replyContract" fields >>= fromJson)
    <*> field "payload" fields

receivedReplyCodec :: Codec a -> Codec (ReceivedReply a)
receivedReplyCodec codec = Codec
  (recordSchema [("origin",S.schemaOf (S.SSum [S.Variant "manual" Nothing [S.Field "value" textSchema True],
    S.Variant "provider" Nothing [S.Field "value" (recordSchema [("binding",bindingSchema),("event",textSchema)]) True]])),("value",codec.schema)])
  (encodeReceivedReply codec.encode) decode
  where
    decode value = do
      fields <- record ["origin","value"] value
      source <- field "origin" fields >>= decodeOrigin
      ReceivedReply source <$> (field "value" fields >>= codec.decode)

encodeReceivedReply :: (a -> Value) -> ReceivedReply a -> Value
encodeReceivedReply encodeValue (ReceivedReply source value) = Object
  [("origin",case source of
      ManualReply surface -> Object [("tag",String "manual"),("value",String surface)]
      ProviderReply binding (EventIdentity event) -> Object [("tag",String "provider"),("value",Object [("binding",encodeBinding binding),("event",String event)])]),
   ("value",encodeValue value)]

decodeOrigin :: Value -> Either Text ReplyOrigin
decodeOrigin value = do
  fields <- record ["tag","value"] value
  case lookup "tag" fields of
    Just (String "manual") -> ManualReply <$> (field "value" fields >>= text)
    Just (String "provider") -> do
      provider <- field "value" fields >>= record ["binding","event"]
      ProviderReply <$> (field "binding" provider >>= decodeBinding) <*> (EventIdentity <$> (field "event" provider >>= text))
    _ -> Left "Invalid reply origin"

json :: ToJSON a => a -> Value
json = String . Text.decodeUtf8 . Bytes.toStrict . encode
fromJson :: FromJSON a => Value -> Either Text a
fromJson value = text value >>= either (Left . Text.pack) Right . eitherDecodeStrict' . Text.encodeUtf8
text :: Value -> Either Text Text
text (String value) = Right value
text _ = Left "Expected text"
field :: Text -> [(Text,Value)] -> Either Text Value
field key fields = maybe (Left ("Missing field: " <> key)) Right (lookup key fields)
record :: [Text] -> Value -> Either Text [(Text,Value)]
record expected (Object fields) = do
  unless (sort (map fst fields) == sort expected) (Left "Unexpected event envelope fields")
  pure fields
record _ _ = Left "Expected event envelope object"
textSchema :: S.Schema
textSchema = S.schemaOf (S.SString Nothing)
recordSchema :: [(Text,S.Schema)] -> S.Schema
recordSchema = S.schemaOf . S.SObject . map (\(key,schema) -> S.Field key schema True)

bindingSchema :: S.Schema
bindingSchema = recordSchema [(key,textSchema) | key <- ["plugin","connector","instanceName","method"]]
encodeBinding :: EventReference -> Value
encodeBinding (EventReference p c i m) = Object
  [("plugin",String p),("connector",String c),("instanceName",String i),("method",String m)]
decodeBinding :: Value -> Either Text EventReference
decodeBinding value = do
  fields <- record ["plugin","connector","instanceName","method"] value
  EventReference <$> (field "plugin" fields >>= text) <*> (field "connector" fields >>= text)
    <*> (field "instanceName" fields >>= text) <*> (field "method" fields >>= text)
