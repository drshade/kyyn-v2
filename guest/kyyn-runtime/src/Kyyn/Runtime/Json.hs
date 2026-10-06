module Kyyn.Runtime.Json
  ( Codec(..), encodeWith, decodeWith, parseValue, printValue, printChunks
  , stringCodec, textCodec, integerCodec, boolCodec, listCodec, optionalCodec
  , record, fields, field, tagged, variant, at
  ) where

import Data.List (sort)
import Text.JSON.Types
import Text.JSON.String
import qualified Data.Text as T

data Codec a = Codec (a -> JSValue) (JSValue -> Either String a)

encodeWith :: Codec a -> a -> JSValue
encodeWith (Codec enc _) = enc

decodeWith :: Codec a -> JSValue -> Either String a
decodeWith (Codec _ dec) = dec

parseValue :: String -> Either String JSValue
parseValue input = runGetJSON readJSValue input >>= profile

printValue :: JSValue -> Either String String
printValue value = do
  checked <- profile value
  pure (showJSValue checked "")

-- Validate and encode incrementally. String escaping remains the JSON library's
-- responsibility; only container punctuation is emitted here.
printChunks :: JSValue -> [Either String String]
printChunks JSNull = [Left "null is outside the wire profile"]
printChunks (JSRational _ _) = [Left "numbers must use strings"]
printChunks (JSBool value) = [Right (showJSValue (JSBool value) "")]
printChunks (JSString value) = stringChunks (fromJSString value)
printChunks (JSArray values) = Right "[" : separated (map printChunks values) ++ [Right "]"]
printChunks (JSObject object) = Right "{" : separated (members [] (fromJSObject object)) ++ [Right "}"]
  where
    members _ [] = []
    members seen ((key,value):rest)
      | key `elem` seen = members seen rest
      | otherwise = (stringChunks key ++ Right ":" : printChunks value) : members (key:seen) rest

separated :: [[Either String String]] -> [Either String String]
separated [] = []
separated [value] = value
separated (value:rest) = value ++ Right "," : separated rest

stringChunks :: String -> [Either String String]
stringChunks value = Right "\"" : parts value
  where
    parts [] = [Right "\""]
    parts characters =
      let (part,rest) = splitAt 1024 characters
          encoded = do
            checked <- scalarText part
            let quoted = showJSValue (JSString (toJSString checked)) ""
            pure (take (length quoted - 2) (drop 1 quoted))
      in encoded : parts rest

profile :: JSValue -> Either String JSValue
profile JSNull = Left "null is outside the wire profile"
profile (JSRational _ _) = Left "numbers must use strings"
profile (JSBool b) = Right (JSBool b)
profile (JSString s) = JSString . toJSString <$> scalarText (fromJSString s)
profile (JSArray values) = JSArray <$> mapM profile values
profile (JSObject obj) = do
  retained <- mapM checkField (firstKeys [] (fromJSObject obj))
  pure (JSObject (toJSObject retained))
  where
    checkField (key, value) = (,) <$> scalarText key <*> at key (profile value)
    firstKeys _ [] = []
    firstKeys seen ((key,value):rest)
      | key `elem` seen = firstKeys seen rest
      | otherwise = (key,value) : firstKeys (key:seen) rest

scalarText :: String -> Either String String
scalarText value
  | any (\c -> c >= '\xD800' && c <= '\xDFFF') value = Left "surrogate character is outside the wire profile"
  | otherwise = Right value

at :: String -> Either String a -> Either String a
at location = either (Left . ((location ++ ": ") ++)) Right

stringCodec :: Codec String
stringCodec = Codec (JSString . toJSString) decodeString
  where
    decodeString (JSString s) = scalarText (fromJSString s)
    decodeString _ = Left "expected string"

integerCodec :: Codec Integer
integerCodec = Codec (encodeWith stringCodec . show) decodeInteger
  where
    decodeInteger value = do
      text <- decodeWith stringCodec value
      case reads text of
        [(n, "")] | show (n :: Integer) == text -> Right n
        _ -> Left "expected canonical integer string"

textCodec :: Codec T.Text
textCodec = Codec (encodeWith stringCodec . T.unpack) decodeText
  where
    decodeText value = do
      characters <- decodeWith stringCodec value
      let packed = T.pack characters
      packed `seq` Right packed

boolCodec :: Codec Bool
boolCodec = Codec JSBool decodeBool
  where
    decodeBool (JSBool b) = Right b
    decodeBool _ = Left "expected boolean"

listCodec :: Codec a -> Codec [a]
listCodec codec = Codec (JSArray . map (encodeWith codec)) decodeList
  where
    decodeList (JSArray values) = sequence
      [at ("[" ++ show i ++ "]") (decodeWith codec value) | (i,value) <- zip [0 :: Int ..] values]
    decodeList _ = Left "expected list"

optionalCodec :: Codec a -> Codec (Maybe a)
optionalCodec codec = Codec enc dec
  where
    enc Nothing = tagged "None" Nothing
    enc (Just a) = tagged "Some" (Just (encodeWith codec a))
    dec value = do
      (name, payload) <- variant value
      case (name, payload) of
        ("None", Nothing) -> Right Nothing
        ("Some", Just a) -> Just <$> at "Some.value" (decodeWith codec a)
        _ -> Left "expected None or Some with one value"

record :: [(String, JSValue)] -> JSValue
record = JSObject . toJSObject

fields :: [String] -> JSValue -> Either String [(String, JSValue)]
fields expected (JSObject obj)
  | sort expected == sort (map fst actual) = Right actual
  | otherwise = Left ("expected fields " ++ show expected ++ "; received " ++ show (map fst actual))
  where actual = fromJSObject obj
fields _ _ = Left "expected object"

field :: String -> Codec a -> [(String, JSValue)] -> Either String a
field name codec values = at name $ case lookup name values of
  Nothing -> Left "missing field"
  Just value -> decodeWith codec value

tagged :: String -> Maybe JSValue -> JSValue
tagged name Nothing = record [("tag", encodeWith stringCodec name)]
tagged name (Just value) = record [("tag", encodeWith stringCodec name), ("value", value)]

variant :: JSValue -> Either String (String, Maybe JSValue)
variant (JSObject obj) = do
  let values = fromJSObject obj
  name <- field "tag" stringCodec values
  case sort (map fst values) of
    ["tag"] -> Right (name, Nothing)
    ["tag", "value"] -> Right (name, lookup "value" values)
    _ -> Left "expected tag and optional value fields"
variant _ = Left "expected tagged object"
