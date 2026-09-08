module Kyyn.Plumbing.Capability.GuestCompilation.Validation (decodeReport) where

import Control.Monad (unless)
import Data.Aeson (Value, Object, eitherDecodeStrict, withObject, withArray, parseJSON, (.:))
import Data.Aeson.Types (Parser, parseEither)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import Data.Foldable (toList)
import Data.List (sort)
import Kyyn.Domain.Diagnostic

decodeReport :: Bytes.ByteString -> Either String ValidationReport
decodeReport bytes = eitherDecodeStrict bytes >>= parseEither
  (withArray "ValidationReport" (fmap ValidationReport . traverse diagnostic . toList))
  where
    diagnostic = exact "Diagnostic" ["severity", "code", "message", "location"] $ \o ->
      Diagnostic <$> (o .: "severity" >>= level) <*> o .: "code" <*> o .: "message"
        <*> (o .: "location" >>= optional place)
    level = exact "Severity" ["tag"] $ \o -> do
      tag <- o .: "tag"
      case tag :: String of
        "Warning" -> pure Warning
        "Error" -> pure Error
        _ -> fail "Unknown diagnostic severity"
    place = exact "DiagnosticLocation" ["tag", "value"] $ \o -> do
      tag <- o .: "tag"
      value <- o .: "value"
      case tag :: String of
        "Fact" -> exact "FactLocation" ["collection", "factId", "field"] (\p ->
          FactLocation <$> p .: "collection" <*> p .: "factId" <*> (p .: "field" >>= optional pureText)) value
        "Source" -> exact "SourceLocation" ["file", "line", "column"] (\p ->
          SourceLocation <$> p .: "file" <*> (p .: "line" >>= integer) <*> (p .: "column" >>= integer)) value
        "Example" -> ExampleLocation <$> pureText value
        _ -> fail "Unknown diagnostic location"
    pureText :: Value -> Parser String
    pureText = parseJSON
    integer value = do
      source <- pureText value
      case reads source of
        [(n, "")] | show (n :: Integer) == source -> pure n
        _ -> fail "Expected canonical integer string"

optional :: (Value -> Parser a) -> Value -> Parser (Maybe a)
optional parse = withObject "Optional" $ \o -> do
  tag <- o .: "tag"
  case tag :: String of
    "None" | Keys.keys o == ["tag"] -> pure Nothing
    "Some" | sort (Keys.keys o) == ["tag", "value"] -> Just <$> (o .: "value" >>= parse)
    _ -> fail "Expected None or Some with one value"

exact :: String -> [Key] -> (Object -> Parser a) -> Value -> Parser a
exact label expected parse = withObject label $ \o -> do
  unless (sort (Keys.keys o) == sort expected) (fail (label ++ ": unexpected or missing fields"))
  parse o
