module Kyyn.Plumbing.Protocol.ModelTurn (decodeRequest, encodeReply, failureMessage) where

import qualified Agentic.Runtime as A
import Data.Aeson (Value, encode, eitherDecodeStrict)
import Data.Aeson.Types (Parser)
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Model (ModelFailure(..))
import Kyyn.Domain.Secret (secretNameText)
import qualified Kyyn.Runtime.Json as Wire
import qualified Kyyn.Runtime.ModelWire as Wire

decodeRequest :: Value -> Parser A.Conversation
decodeRequest value = either fail pure $ Wire.parseValue (Text.unpack (Text.decodeUtf8 (Lazy.toStrict (encode value))))
  >>= Wire.decodeWith Wire.conversationCodec

encodeReply :: Either ModelFailure A.Turn -> Either String Value
encodeReply reply = Wire.printValue (Wire.encodeWith Wire.replyCodec (either (Left . failureMessage) Right reply))
  >>= eitherDecodeStrict . Text.encodeUtf8 . Text.pack

failureMessage :: ModelFailure -> String
failureMessage failure = case failure of
  InvalidModelConfiguration -> "Invalid model configuration; check provider and model in root/model.dhall."
  MissingModelSecret name -> "Missing model secret " ++ secretNameText name ++ ". " ++ setup name
  EmptyModelSecret name -> "Model secret " ++ secretNameText name ++ " is empty. " ++ setup name
  ModelAuthenticationRejected -> "Model authentication was rejected; check the configured credential."
  ModelRateLimited -> "The model provider is rate limiting requests; retry later."
  ModelUnavailable -> "The model provider is unavailable; retry later."
  ModelRequestRejected -> "The model provider rejected the request; check the model name and account access."
  ModelRefused -> "The model refused this request; revise the input or instructions."
  ModelIncomplete -> "The model response was incomplete; retry or reduce the requested output."
  InvalidModelResponse -> "The model provider returned an invalid response; retry the tool."
  where
    setup name = "Set it with: kyyn-v2 --kb PATH secret set " ++ secretNameText name
