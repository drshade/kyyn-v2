module Kyyn.Contract.Wire (toWire, fromWire) where

import qualified Agentic.Value as A
import qualified Data.Text as Text
import Text.JSON.Types

toWire :: A.Value -> JSValue
toWire value = case value of
  A.Null -> JSNull
  A.Bool b -> JSBool b
  A.String text -> JSString (toJSString (Text.unpack text))
  A.Integer n -> JSRational False (fromInteger n)
  A.Number n -> JSRational False (toRational n)
  A.Array values -> JSArray (map toWire values)
  A.Object values -> JSObject (toJSObject [(Text.unpack name,toWire inner) | (name,inner) <- values])

fromWire :: JSValue -> A.Value
fromWire value = case value of
  JSNull -> A.Null
  JSBool b -> A.Bool b
  JSString text -> A.String (Text.pack (fromJSString text))
  JSRational _ n -> A.Number (fromRational n)
  JSArray values -> A.Array (map fromWire values)
  JSObject fields -> A.Object [(Text.pack name,fromWire inner) | (name,inner) <- fromJSObject fields]
