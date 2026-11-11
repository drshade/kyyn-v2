module Kyyn.Runtime.AgenticContract (fromWireCodec) where

import qualified Agentic.Contract as A
import qualified Agentic.Schema as A
import qualified Agentic.Value as A
import qualified Data.Text as Text
import Kyyn.Contract.Wire (fromWire, checkedToWire)
import qualified Kyyn.Runtime.Json as Wire

-- | Adapt generated codecs to Agentic values; numeric leaves are model-only.
fromWireCodec :: A.Schema -> Wire.Codec a -> A.Codec a
fromWireCodec schema codec = A.Codec schema (fromWire . Wire.encodeWith codec) decode
  where
    decode value = case rejectNull value >> checkedToWire value >>= Wire.decodeWith codec of
      Left message -> Left (Text.pack message)
      Right result -> Right result
    rejectNull A.Null = Left "Expected a model value; optional values use None/Some tags"
    rejectNull (A.Array values) = mapM_ rejectNull values
    rejectNull (A.Object values) = mapM_ (rejectNull . snd) values
    rejectNull _ = Right ()
