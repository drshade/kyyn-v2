-- | Canonical path components for logical collection names and fact identities.
module Kyyn.Domain.StoragePath (encodeComponent, decodeComponent) where

import Control.Monad (unless)
import qualified Data.ByteString as Bytes
import Data.Char (digitToInt, isHexDigit)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Numeric (showHex)

encodeComponent :: Text -> String
encodeComponent value
  | not (Text.null value) && Text.all safe value && value `notElem` reserved = Text.unpack value
  | otherwise = '~' : concatMap hex (Bytes.unpack (Text.encodeUtf8 value))
  where
    safe c = c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_'
    reserved = map Text.pack (["index", "con", "prn", "aux", "nul"] ++
      [prefix ++ show n | prefix <- ["com", "lpt"], n <- [1 :: Int .. 9]])
    hex byte = let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits

decodeComponent :: String -> Either String Text
decodeComponent component = do
  value <- case component of
    '~' : digits -> do
      bytes <- decodeHex digits
      either (Left . show) Right (Text.decodeUtf8' (Bytes.pack bytes))
    _ -> Right (Text.pack component)
  unless (encodeComponent value == component) (Left "Noncanonical stored path component")
  pure value
  where
    decodeHex [] = Right []
    decodeHex (a:b:rest) | isHexDigit a && isHexDigit b =
      (fromIntegral (16 * digitToInt a + digitToInt b) :) <$> decodeHex rest
    decodeHex _ = Left "Invalid hexadecimal stored path component"
