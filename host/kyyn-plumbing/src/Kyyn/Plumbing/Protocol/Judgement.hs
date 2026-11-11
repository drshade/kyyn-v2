module Kyyn.Plumbing.Protocol.Judgement (decodeRequest, encodeReply) where

import Kyyn.Types.Wire (validateWire)
import Agentic.Questions (JudgeRequest, Answer)
import Data.Aeson (Value)
import Data.Aeson.Types (Parser)
import Kyyn.Domain.Model (ModelFailure)
import Kyyn.Plumbing.Protocol.ModelTurn (failureMessage)
import qualified Kyyn.Runtime.Json as Wire
import qualified Kyyn.Runtime.JudgementWire as Wire

decodeRequest :: Value -> Parser JudgeRequest
decodeRequest value = either fail pure $ validateWire value >> Wire.decodeWith Wire.requestCodec value

encodeReply :: Either ModelFailure [Answer] -> Either String Value
encodeReply reply = do
  let value = Wire.encodeWith Wire.replyCodec (either (Left . failureMessage) Right reply)
  validateWire value
  pure value
