{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.Json (exactObject, optionalValue, parseOptionalValue) where

import Control.Monad (unless)
import Data.Aeson (Value, Object, withObject, ToJSON, FromJSON, object, (.=), (.:))
import Data.Text (Text)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import Data.Aeson.Types (Parser)
import Data.List (sort)

exactObject :: String -> [Key] -> (Object -> Parser a) -> Value -> Parser a
exactObject label expected parse = withObject label $ \fields -> do
  unless (sort (Keys.keys fields) == sort expected) (fail (label ++ ": unexpected or missing fields"))
  parse fields

-- The shared wire profile represents optionals as tagged values, never null.
optionalValue :: ToJSON a => Maybe a -> Value
optionalValue Nothing = object ["tag" .= ("None" :: Text)]
optionalValue (Just value) = object ["tag" .= ("Some" :: Text),"value" .= value]

parseOptionalValue :: FromJSON a => Value -> Parser (Maybe a)
parseOptionalValue value = withObject "optional value" (\fields -> do
  tag <- fields .: "tag"
  case tag :: Text of
    "None" -> exactObject "None" ["tag"] (const (pure Nothing)) value
    "Some" -> exactObject "Some" ["tag","value"] (\selected -> Just <$> selected .: "value") value
    _ -> fail "Unknown optional value tag") value
