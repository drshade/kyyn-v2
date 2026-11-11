module GitHub.Json (parse, field, text, integer, boolean, array, nullable, optional, has, escape) where

import Data.Char (chr)
import Data.Foldable (toList)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.ByteString as Bytes
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap

parse :: Text -> Either Text Aeson.Value
parse = either (const (Left "Invalid GitHub JSON response")) Right . Aeson.eitherDecodeStrict' . Encoding.encodeUtf8
field :: Text -> Aeson.Value -> Either Text Aeson.Value
field key (Aeson.Object fields) = maybe (Left ("Missing GitHub field: " <> key)) Right (KeyMap.lookup (Key.fromText key) fields)
field _ _ = Left "Expected GitHub object"
text :: Aeson.Value -> Either Text Text
text (Aeson.String value) = Right value
text _ = Left "Expected GitHub text field"
integer :: Aeson.Value -> Either Text Integer
integer value@(Aeson.Number _) | Aeson.Success number <- Aeson.fromJSON value, number >= 0 = Right number
integer _ = Left "Expected nonnegative GitHub integer"
boolean :: Aeson.Value -> Either Text Bool
boolean (Aeson.Bool value) = Right value
boolean _ = Left "Expected GitHub boolean"
array :: Aeson.Value -> Either Text [Aeson.Value]
array (Aeson.Array values) = Right (toList values)
array _ = Left "Expected GitHub array"
nullable :: (Aeson.Value -> Either Text a) -> Aeson.Value -> Either Text (Maybe a)
nullable _ Aeson.Null = Right Nothing
nullable decode value = Just <$> decode value
optional :: Text -> (Aeson.Value -> Either Text a) -> Aeson.Value -> Either Text (Maybe a)
optional key decode value@(Aeson.Object _) = if has key value then field key value >>= nullable decode else Right Nothing
optional _ _ _ = Left "Expected GitHub object"
has :: Text -> Aeson.Value -> Bool
has key (Aeson.Object fields) = KeyMap.member (Key.fromText key) fields
has _ _ = False
escape :: Text -> Text
escape = Text.pack . concatMap encode . Bytes.unpack . Encoding.encodeUtf8
  where
    encode byte | byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 || byte >= 48 && byte <= 57 || byte `elem` [45,46,95,126] = [chr (fromIntegral byte)]
                | otherwise = ['%',hex (byte `div` 16),hex (byte `mod` 16)]
    hex n = "0123456789ABCDEF" !! fromIntegral n
