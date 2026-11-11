module Kyyn.Runtime.Contract (runtimeCodec, toWire, fromWire) where

import qualified Agentic.Contract as A
import qualified Data.Text as Text
import qualified Kyyn.Runtime.Json as Wire
import Kyyn.Contract.Wire (toWire, fromWire)

runtimeCodec :: A.Codec a -> Wire.Codec a
runtimeCodec (A.Codec _ encode decode) = Wire.Codec (toWire . encode)
  (either (Left . Text.unpack) Right . decode . fromWire)
