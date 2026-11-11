module Kyyn.Types.Wire (decodeWire, parseWire, validateWire, encodeWire, scalarText) where

import Data.Aeson (Value(..), FromJSON, encode, parseJSON)
import Data.Aeson.Parser (jsonNoDup)
import Data.Aeson.Types (parseEither)
import Data.Attoparsec.ByteString.Char8 (parseOnly, skipSpace, endOfInput)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text

decodeWire :: FromJSON a => Bytes.ByteString -> Either String a
decodeWire bytes = parseWire bytes >>= parseEither parseJSON

parseWire :: Bytes.ByteString -> Either String Value
parseWire bytes = do
  value <- parseOnly (skipSpace *> jsonNoDup <* skipSpace <* endOfInput) bytes
  validateWire value
  pure value

-- Aeson Text values contain only Unicode scalar values. Validate String inputs
-- before packing: Text.pack replaces lone surrogates rather than refusing them.
scalarText :: String -> Either String Text.Text
scalarText characters
  | any (\c -> c >= '\xD800' && c <= '\xDFFF') characters =
      Left "surrogate character is outside the wire profile"
  | otherwise = Right (Text.pack characters)

validateWire :: Value -> Either String ()
validateWire Null = Left "null is outside the wire profile"
validateWire (Number _) = Left "numbers must use strings"
validateWire (String text) = Text.length text `seq` Right ()
validateWire (Array values) = mapM_ validateWire values
validateWire (Object values) = mapM_ validateWire values
validateWire _ = Right ()

encodeWire :: Value -> Either String [Bytes.ByteString]
encodeWire value = do
  validateWire value
  pure (Lazy.toChunks (encode value))
