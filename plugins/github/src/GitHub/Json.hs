{-# LANGUAGE OverloadedStrings #-}
module GitHub.Json (parse, field, text, integer, boolean, array, nullable, optional, has, escape) where

import Data.Char (chr)
import Data.Ratio (numerator, denominator)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.ByteString as Bytes
import Text.JSON.Types
import Text.JSON.String (runGetJSON, readJSValue)

parse :: Text -> Either Text JSValue
parse = either (const (Left "Invalid GitHub JSON response")) Right . runGetJSON readJSValue . Text.unpack
field :: Text -> JSValue -> Either Text JSValue
field key (JSObject fields) = maybe (Left ("Missing GitHub field: " <> key)) Right (lookup (Text.unpack key) (fromJSObject fields))
field _ _ = Left "Expected GitHub object"
text :: JSValue -> Either Text Text
text (JSString value) = Right (Text.pack (fromJSString value))
text _ = Left "Expected GitHub text field"
integer :: JSValue -> Either Text Integer
integer (JSRational _ value) | denominator value == 1 && numerator value >= 0 = Right (numerator value)
integer _ = Left "Expected nonnegative GitHub integer"
boolean :: JSValue -> Either Text Bool
boolean (JSBool value) = Right value
boolean _ = Left "Expected GitHub boolean"
array :: JSValue -> Either Text [JSValue]
array (JSArray values) = Right values
array _ = Left "Expected GitHub array"
nullable :: (JSValue -> Either Text a) -> JSValue -> Either Text (Maybe a)
nullable _ JSNull = Right Nothing
nullable decode value = Just <$> decode value
optional :: Text -> (JSValue -> Either Text a) -> JSValue -> Either Text (Maybe a)
optional key decode value@(JSObject _) = if has key value then field key value >>= nullable decode else Right Nothing
optional _ _ _ = Left "Expected GitHub object"
has :: Text -> JSValue -> Bool
has key (JSObject fields) = any ((== Text.unpack key) . fst) (fromJSObject fields)
has _ _ = False
escape :: Text -> Text
escape = Text.pack . concatMap encode . Bytes.unpack . Encoding.encodeUtf8
  where
    encode byte | byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 || byte >= 48 && byte <= 57 || byte `elem` [45,46,95,126] = [chr (fromIntegral byte)]
                | otherwise = ['%',hex (byte `div` 16),hex (byte `mod` 16)]
    hex n = "0123456789ABCDEF" !! fromIntegral n
