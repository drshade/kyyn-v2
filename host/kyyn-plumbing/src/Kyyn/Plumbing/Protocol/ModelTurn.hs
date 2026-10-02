module Kyyn.Plumbing.Protocol.ModelTurn (decodeRequest, encodeReply) where

import qualified Agentic.Runtime as A
import Data.Aeson (Value, encode, eitherDecodeStrict)
import Data.Aeson.Types (Parser)
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Model (ModelFailure)
import qualified Kyyn.Runtime.Json as Wire
import qualified Kyyn.Runtime.ModelWire as Wire

decodeRequest :: Value -> Parser A.Conversation
decodeRequest value = either fail pure $ Wire.parseValue (Text.unpack (Text.decodeUtf8 (Lazy.toStrict (encode value))))
  >>= Wire.decodeWith Wire.conversationCodec

encodeReply :: Either ModelFailure A.Turn -> Either String Value
encodeReply reply = Wire.printValue (Wire.encodeWith Wire.replyCodec (either (Left . show) Right reply))
  >>= eitherDecodeStrict . Text.encodeUtf8 . Text.pack
