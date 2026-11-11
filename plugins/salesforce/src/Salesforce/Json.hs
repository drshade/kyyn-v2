module Salesforce.Json (parse, member, text, integer, boolean, array, optionalText, optionalInteger, escape, form, canonical) where

import Data.Text (Text)
import Network.HTTP.Types.URI (urlEncode, renderSimpleQuery)
import Data.Foldable (toList)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Parser (jsonNoDup)
import Data.Attoparsec.ByteString.Char8 (parseOnly, skipSpace, endOfInput)
import qualified Data.Aeson.Encoding as Encoding
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.Scientific (formatScientific, FPFormat(Fixed))

parse :: Text -> Either Text Aeson.Value
-- Reject duplicate keys before interpreting records or pagination controls.
parse = either (const (Left "Invalid or duplicate-key JSON response")) Right .
  parseOnly (skipSpace *> jsonNoDup <* skipSpace <* endOfInput) . Text.encodeUtf8

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
escape = Text.decodeUtf8 . urlEncode True . Text.encodeUtf8

form :: [(Text,Text)] -> Text
form = Text.decodeUtf8 . renderSimpleQuery False .
  map (\(key,value) -> (Text.encodeUtf8 key,Text.encodeUtf8 value))

-- Preserve sorted keys and plain, exact decimal spelling for stored records.
-- Aeson owns JSON escaping/containers; scientific owns decimal formatting.
canonical :: Aeson.Value -> Text
canonical = Text.decodeUtf8 . Lazy.toStrict . Encoding.encodingToLazyByteString . encode
  where
    encode (Aeson.Object values) = Encoding.pairs
      (foldMap (\(key,value) -> Encoding.pair key (encode value)) (KeyMap.toAscList values))
    encode (Aeson.Array values) = Encoding.list encode (toList values)
    encode (Aeson.Number value) =
      let decimal = Text.pack (formatScientific Fixed Nothing value)
          plain = maybe decimal id (Text.stripSuffix ".0" decimal)
      -- Only the library's valid numeric spelling enters the raw-number builder.
      in Encoding.unsafeToEncoding (Builder.byteString (Text.encodeUtf8 plain))
    encode value = Aeson.toEncoding value
