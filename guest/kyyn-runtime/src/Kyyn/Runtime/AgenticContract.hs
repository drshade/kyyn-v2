module Kyyn.Runtime.AgenticContract (fromWireCodec) where

import qualified Agentic.Contract as A
import qualified Agentic.Schema as A
import qualified Agentic.Value as A
import qualified Data.Text as Text
import qualified Kyyn.Runtime.Json as Wire
import Text.JSON.Types

-- | Keep generated model contracts in the same value representation as the guest wire.
fromWireCodec :: A.Schema -> Wire.Codec a -> A.Codec a
fromWireCodec schema codec = A.Codec schema (toModel . Wire.encodeWith codec) decode
  where
    decode value = case fromModel value >>= Wire.decodeWith codec of
      Left message -> Left (Text.pack message)
      Right result -> Right result

toModel :: JSValue -> A.Value
toModel (JSString text) = A.String (Text.pack (fromJSString text))
toModel (JSBool value) = A.Bool value
toModel (JSArray values) = A.Array (map toModel values)
toModel (JSObject fields) = A.Object [(Text.pack key,toModel value) | (key,value) <- fromJSObject fields]
toModel JSNull = error "Generated Kyyn codecs cannot emit null"
toModel (JSRational _ n) = A.Number (fromRational n)

fromModel :: A.Value -> Either String JSValue
fromModel (A.String value) = Right (JSString (toJSString (Text.unpack value)))
fromModel (A.Bool value) = Right (JSBool value)
fromModel (A.Integer value) = Right (JSRational False (fromInteger value))
fromModel (A.Number value)
  | isNaN value || isInfinite value = Left "Expected finite model number"
  | otherwise = Right (JSRational False (toRational value))
fromModel (A.Array values) = JSArray <$> traverse fromModel values
fromModel (A.Object values) = JSObject . toJSObject <$> traverse
  (\(key,value) -> (,) (Text.unpack key) <$> fromModel value) values
fromModel _ = Left "Expected a model value; optional values use None/Some tags"
