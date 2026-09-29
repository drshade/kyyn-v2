module MicrosoftGraph.Json (parse, member, text, integer, boolean, array, optionalText, optionalInteger, escape, form) where

import Data.Char (chr)
import Data.List (intercalate)
import Data.Ratio (numerator, denominator)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Text.JSON.Types
import Text.JSON.String (runGetJSON, readJSValue)

parse :: String -> Either String JSValue
parse = either (const (Left "Invalid JSON response")) Right . runGetJSON readJSValue

member :: String -> JSValue -> Either String JSValue
member key (JSObject values) = maybe (Left ("Missing response field: " ++ key)) Right (lookup key (fromJSObject values))
member _ _ = Left "Expected response object"

text :: JSValue -> Either String String
text (JSString value) = Right (fromJSString value)
text _ = Left "Expected text response field"

integer :: JSValue -> Either String Int
integer (JSRational _ value) | denominator value == 1 && numerator value >= 0 && numerator value <= toInteger (maxBound :: Int) = Right (fromInteger (numerator value))
integer _ = Left "Expected nonnegative integer response field"

boolean :: JSValue -> Either String Bool
boolean (JSBool value) = Right value
boolean _ = Left "Expected boolean response field"

array :: JSValue -> Either String [JSValue]
array (JSArray values) = Right values
array _ = Left "Expected response array"

optionalText :: String -> JSValue -> Either String (Maybe String)
optionalText key value@(JSObject values) = case lookup key (fromJSObject values) of
  Nothing -> Right Nothing
  Just JSNull -> Right Nothing
  Just _ -> Just <$> (member key value >>= text)
optionalText _ _ = Left "Expected response object"

optionalInteger :: String -> Int -> JSValue -> Either String Int
optionalInteger key fallback value@(JSObject values) = case lookup key (fromJSObject values) of
  Nothing -> Right fallback
  Just _ -> member key value >>= integer
optionalInteger _ _ _ = Left "Expected response object"

escape :: String -> String
escape = concatMap encode . Bytes.unpack . Text.encodeUtf8 . Text.pack
  where
    encode byte | byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 || byte >= 48 && byte <= 57 || byte `elem` [45,46,95,126] = [chr (fromIntegral byte)]
                | otherwise = ['%',hex (byte `div` 16),hex (byte `mod` 16)]
    hex n = "0123456789ABCDEF" !! fromIntegral n

form :: [(String,String)] -> String
form = intercalate "&" . map (\(key,value) -> escape key ++ "=" ++ escape value)
