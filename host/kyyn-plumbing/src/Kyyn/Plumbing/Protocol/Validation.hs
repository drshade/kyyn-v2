module Kyyn.Plumbing.Protocol.Validation (decodeReport, parseReport, validationSources) where

import Control.Monad (unless)
import Data.Aeson (Value, Object, eitherDecodeStrict, withObject, withArray, parseJSON, (.:))
import Data.Aeson.Types (Parser, parseEither)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import Data.Foldable (toList)
import Data.List (sort, nub)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.DataType (DataType(..), haskellType, typeModules)
import Kyyn.Domain.Path (RelativePath, relativePath)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources, bindingModule)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)

validationSources :: DataType -> String -> [(RelativePath, Bytes.ByteString)] -> Either String GuestSources
validationSources root selected sources = do
  moduleName <- bindingModule selected
  codec <- generateCodecs "KyynValidationCodec" root
  entryPath <- relativePath "KyynValidationEntry.hs"
  codecPath <- relativePath "KyynValidationCodec.hs"
  let entry = unlines $
        ["module KyynValidationEntry where"] ++
        ["import qualified " ++ name | name <- nub (moduleName : typeModules root)] ++
        [
         "import KyynValidationCodec", "import Kyyn.Runtime.Json",
         "import Kyyn.Runtime.Validation", "import Kyyn.Types.Diagnostic (ValidationReport)",
         "validate :: " ++ haskellType root ++ " -> ValidationReport", "validate = " ++ selected,
         "main :: IO ()", "main = do", "  input <- getContents",
         "  value <- either fail pure (parseValue input >>= decodeWith rootCodec)",
         "  output <- either fail pure (encodeReport (validate value))", "  putStrLn output"]
      utf8 = Text.encodeUtf8 . Text.pack
  guestSources entryPath (sources ++ [(entryPath, utf8 entry), (codecPath, utf8 codec)])

decodeReport :: Bytes.ByteString -> Either String ValidationReport
decodeReport bytes = eitherDecodeStrict bytes >>= parseEither parseReport

parseReport :: Value -> Parser ValidationReport
parseReport = withArray "ValidationReport" (fmap ValidationReport . traverse diagnostic . toList)
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
        [(n, "")] | n > 0 && show (n :: Integer) == source -> pure n
        _ -> fail "Expected positive canonical source coordinate"

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
