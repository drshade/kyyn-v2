module Kyyn.Runtime.Json
  ( Codec(..), encodeWith, decodeWith, parseValue, printValue, printChunks
  , stringCodec, textCodec, integerCodec, boolCodec, listCodec, optionalCodec
  , record, fields, field, tagged, variant, at
  ) where

import Data.List (sort, nub)
import Data.Aeson (Value(..), toJSON)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as Keys
import Data.Foldable (toList)
import qualified Data.ByteString as Bytes
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Kyyn.Types.Wire (parseWire, encodeWire, scalarText)

data Codec a = Codec (a -> Value) (Value -> Either String a)

encodeWith :: Codec a -> a -> Value
encodeWith (Codec enc _) = enc

decodeWith :: Codec a -> Value -> Either String a
decodeWith (Codec _ dec) = dec

parseValue :: String -> Either String Value
parseValue input = scalarText input >>= parseWire . T.encodeUtf8

printValue :: Value -> Either String String
printValue value = T.unpack . T.decodeUtf8 . Bytes.concat <$> printChunks value

printChunks :: Value -> Either String [Bytes.ByteString]
printChunks = encodeWire

at :: String -> Either String a -> Either String a
at location = either (Left . ((location ++ ": ") ++)) Right

stringCodec :: Codec String
stringCodec = Codec encodeString decodeString
  where
    encodeString characters = case scalarText characters of
      Left message -> error message
      Right text -> String text
    decodeString (String s) = Right (T.unpack s)
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
textCodec = Codec String decodeText
  where
    decodeText (String text) = Right text
    decodeText _ = Left "expected string"

boolCodec :: Codec Bool
boolCodec = Codec Bool decodeBool
  where
    decodeBool (Bool b) = Right b
    decodeBool _ = Left "expected boolean"

listCodec :: Codec a -> Codec [a]
listCodec codec = Codec (toJSON . map (encodeWith codec)) decodeList
  where
    decodeList (Array values) = sequence
      [at ("[" ++ show i ++ "]") (decodeWith codec value) | (i,value) <- zip [0 :: Int ..] (toList values)]
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

record :: [(String, Value)] -> Value
record values
  | length names /= length (nub names) = error "duplicate record keys"
  | otherwise = Object (Keys.fromList [(Key.fromText (either error id (scalarText key)),value) | (key,value) <- values])
  where names = map fst values

fields :: [String] -> Value -> Either String [(String, Value)]
fields expected (Object obj)
  | sort expected == sort (map fst actual) = Right actual
  | otherwise = Left ("expected fields " ++ show expected ++ "; received " ++ show (map fst actual))
  where actual = [(Key.toString key,value) | (key,value) <- Keys.toList obj]
fields _ _ = Left "expected object"

field :: String -> Codec a -> [(String, Value)] -> Either String a
field name codec values = at name $ case lookup name values of
  Nothing -> Left "missing field"
  Just value -> decodeWith codec value

tagged :: String -> Maybe Value -> Value
tagged name Nothing = record [("tag", encodeWith stringCodec name)]
tagged name (Just value) = record [("tag", encodeWith stringCodec name), ("value", value)]

variant :: Value -> Either String (String, Maybe Value)
variant (Object obj) = do
  let values = [(Key.toString key,value) | (key,value) <- Keys.toList obj]
  name <- field "tag" stringCodec values
  case sort (map fst values) of
    ["tag"] -> Right (name, Nothing)
    ["tag", "value"] -> Right (name, lookup "value" values)
    _ -> Left "expected tag and optional value fields"
variant _ = Left "expected tagged object"
