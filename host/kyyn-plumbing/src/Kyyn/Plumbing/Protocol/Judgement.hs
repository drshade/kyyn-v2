module Kyyn.Plumbing.Protocol.Judgement (decodeRequest, encodeReply) where

import Agentic.Questions (JudgeRequest, Answer)
import Data.Aeson (Value, encode, eitherDecodeStrict)
import Data.Aeson.Types (Parser)
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Model (ModelFailure)
import Kyyn.Plumbing.Protocol.ModelTurn (failureMessage)
import qualified Kyyn.Runtime.Json as Wire
import qualified Kyyn.Runtime.JudgementWire as Wire

decodeRequest :: Value -> Parser JudgeRequest
decodeRequest value = either fail pure $ Wire.parseValue (Text.unpack (Text.decodeUtf8 (Lazy.toStrict (encode value))))
  >>= Wire.decodeWith Wire.requestCodec

encodeReply :: Either ModelFailure [Answer] -> Either String Value
encodeReply reply = Wire.printValue (Wire.encodeWith Wire.replyCodec (either (Left . failureMessage) Right reply))
  >>= eitherDecodeStrict . Text.encodeUtf8 . Text.pack
