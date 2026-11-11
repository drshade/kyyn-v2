module Kyyn.Plumbing.Protocol.ModelTurn (decodeRequest, encodeReply, failureMessage) where

import Kyyn.Types.Wire (validateWire)
import qualified Agentic.Runtime as A
import Data.Aeson (Value)
import Data.Aeson.Types (Parser)
import Kyyn.Domain.Model (ModelFailure(..))
import Kyyn.Domain.Secret (secretNameText)
import qualified Kyyn.Runtime.Json as Wire
import qualified Kyyn.Runtime.ModelWire as Wire

decodeRequest :: Value -> Parser A.Conversation
decodeRequest value = either fail pure $ validateWire value >> Wire.decodeWith Wire.conversationCodec value

encodeReply :: Either ModelFailure A.Turn -> Either String Value
encodeReply reply = do
  let value = Wire.encodeWith Wire.replyCodec (either (Left . failureMessage) Right reply)
  validateWire value
  pure value

failureMessage :: ModelFailure -> String
failureMessage failure = case failure of
  InvalidModelConfiguration -> "Invalid model configuration; check the model configuration in root/kb.dhall."
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
