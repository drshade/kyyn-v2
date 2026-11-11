module MicrosoftGraph.Json (parse, member, text, integer, boolean, array, optionalText, optionalInteger, escape, form) where

import Data.Text (Text)
import Data.Char (chr)
import Data.Foldable (toList)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap

parse :: Text -> Either Text Aeson.Value
parse = either (const (Left "Invalid JSON response")) Right . Aeson.eitherDecodeStrict' . Text.encodeUtf8

member :: Text -> Aeson.Value -> Either Text Aeson.Value
member key (Aeson.Object values) = maybe (Left ("Missing response field: " <> key)) Right (KeyMap.lookup (Key.fromText key) values)
member _ _ = Left "Expected response object"

text :: Aeson.Value -> Either Text Text
text (Aeson.String value) = Right value
text _ = Left "Expected text response field"

integer :: Aeson.Value -> Either Text Int
integer value@(Aeson.Number _) | Aeson.Success number <- Aeson.fromJSON value, number >= 0 = Right number
integer _ = Left "Expected nonnegative integer response field"

boolean :: Aeson.Value -> Either Text Bool
boolean (Aeson.Bool value) = Right value
boolean _ = Left "Expected boolean response field"

array :: Aeson.Value -> Either Text [Aeson.Value]
array (Aeson.Array values) = Right (toList values)
array _ = Left "Expected response array"

optionalText :: Text -> Aeson.Value -> Either Text (Maybe Text)
optionalText key value@(Aeson.Object values) = case KeyMap.lookup (Key.fromText key) values of
  Nothing -> Right Nothing
  Just Aeson.Null -> Right Nothing
  Just _ -> Just <$> (member key value >>= text)
optionalText _ _ = Left "Expected response object"

optionalInteger :: Text -> Int -> Aeson.Value -> Either Text Int
optionalInteger key fallback value@(Aeson.Object values) = case KeyMap.lookup (Key.fromText key) values of
  Nothing -> Right fallback
  Just _ -> member key value >>= integer
optionalInteger _ _ _ = Left "Expected response object"

escape :: Text -> Text
escape = Text.pack . concatMap encode . Bytes.unpack . Text.encodeUtf8
  where
    encode byte | byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 || byte >= 48 && byte <= 57 || byte `elem` [45,46,95,126] = [chr (fromIntegral byte)]
                | otherwise = ['%',hex (byte `div` 16),hex (byte `mod` 16)]
    hex n = "0123456789ABCDEF" !! fromIntegral n

form :: [(Text,Text)] -> Text
form = Text.intercalate "&" . map (\(key,value) -> escape key <> "=" <> escape value)
