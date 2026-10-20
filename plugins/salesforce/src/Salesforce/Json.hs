{-# LANGUAGE OverloadedStrings #-}
module Salesforce.Json (parse, member, text, integer, boolean, array, optionalText, optionalInteger, canonical, escape, form) where

import Data.Text (Text)
import Data.Char (chr)
import Data.List (sortOn, groupBy)
import Data.Ratio (numerator, denominator)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Text.JSON.Types
import Text.JSON.String (runGetJSON, readJSValue, showJSValue)

parse :: Text -> Either Text JSValue
parse = either (const (Left "Invalid JSON response")) Right . runGetJSON readJSValue . Text.unpack

member :: Text -> JSValue -> Either Text JSValue
member key (JSObject values) = maybe (Left ("Missing response field: " <> key)) Right (lookup (Text.unpack key) (fromJSObject values))
member _ _ = Left "Expected response object"

text :: JSValue -> Either Text Text
text (JSString value) = let packed = Text.pack (fromJSString value) in packed `seq` Right packed
text _ = Left "Expected text response field"

integer :: JSValue -> Either Text Int
integer (JSRational _ value) | denominator value == 1 && numerator value >= 0 && numerator value <= toInteger (maxBound :: Int) = Right (fromInteger (numerator value))
integer _ = Left "Expected nonnegative integer response field"

boolean :: JSValue -> Either Text Bool
boolean (JSBool value) = Right value
boolean _ = Left "Expected boolean response field"

array :: JSValue -> Either Text [JSValue]
array (JSArray values) = Right values
array _ = Left "Expected response array"

optionalText :: Text -> JSValue -> Either Text (Maybe Text)
optionalText key value@(JSObject values) = case lookup (Text.unpack key) (fromJSObject values) of
  Nothing -> Right Nothing
  Just JSNull -> Right Nothing
  Just _ -> Just <$> (member key value >>= text)
optionalText _ _ = Left "Expected response object"

optionalInteger :: Text -> Int -> JSValue -> Either Text Int
optionalInteger key fallback value@(JSObject values) = case lookup (Text.unpack key) (fromJSObject values) of
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

-- The library parser gives exact rationals, but its default numeric renderer
-- converts them to Double. Serialize terminating decimals directly so money and
-- large integers survive capture. JSON-derived rationals have finite decimals.
canonical :: JSValue -> Either Text Text
canonical (JSObject fields) = do
  let ordered = sortOn fst (fromJSObject fields)
  if any ((> 1) . length) (groupBy (\a b -> fst a == fst b) ordered)
    then Left "Duplicate JSON object key" else pure ()
  values <- mapM (\(key,value) -> do
    rendered <- canonical value
    pure (Text.pack (showJSValue (JSString (toJSString key)) "") <> ":" <> rendered)) ordered
  pure ("{" <> Text.intercalate "," values <> "}")
canonical (JSArray values) = do
  rendered <- mapM canonical values
  pure ("[" <> Text.intercalate "," rendered <> "]")
canonical (JSRational _ value) =
  let n = numerator value; d = denominator value
      (whole,remainder) = abs n `divMod` d
      digits 0 = ""
      digits r = let (digit,next) = (r * 10) `divMod` d in show digit ++ digits next
      removeFactor factor x | x `mod` factor == 0 = removeFactor factor (x `div` factor)
                            | otherwise = x
  in if removeFactor 5 (removeFactor 2 d) /= 1 then Left "Non-terminating JSON number"
     else Right (Text.pack ((if n < 0 then "-" else "") ++ show whole ++
       if remainder == 0 then "" else "." ++ digits remainder))
canonical value = Right (Text.pack (showJSValue value ""))
