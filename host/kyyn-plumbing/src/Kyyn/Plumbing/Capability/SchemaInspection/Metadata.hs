module Kyyn.Plumbing.Capability.SchemaInspection.Metadata
  ( metadataAdapter, decodeMetadata, evaluateMetadata ) where

import Control.Monad (unless)
import Data.Aeson (Value, Object, eitherDecodeStrict, withObject, (.:))
import Data.Aeson.Types (Parser, parseEither)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as Bytes
import Data.List (sort)
import Effectful (Eff, (:>))
import Kyyn.Types.SchemaMetadata
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestExecution
import Kyyn.Plumbing.Capability.GuestCompilation.Types (bindingModule)
import Kyyn.Plumbing.Capability.ProcessExecution

metadataAdapter :: String -> Either String String
metadataAdapter selected = do
  moduleName <- bindingModule selected
  pure (unlines ["module KyynMetadataEntry where", "import qualified " ++ moduleName,
      "import Kyyn.Runtime.SchemaMetadata (encodeMetadata)",
      "main :: IO ()", "main = either fail putStrLn (encodeMetadata " ++ selected ++ ")"])

decodeMetadata :: Bytes.ByteString -> Either String SchemaMetadata
decodeMetadata bytes = eitherDecodeStrict bytes >>= parseEither metadata
  where
    metadata = exact "SchemaMetadata" ["roles", "fieldRoles", "collections"] $ \o ->
      SchemaMetadata <$> (o .: "roles" >>= mapM roleDecl)
        <*> (o .: "fieldRoles" >>= mapM fieldRole)
        <*> (o .: "collections" >>= mapM collectionDecl)
    roleDecl = exact "RoleDecl" ["name", "description", "affordance"] $ \o ->
      RoleDecl <$> o .: "name" <*> o .: "description" <*> (o .: "affordance" >>= affordanceValue)
    affordanceValue = exact "Affordance" ["tag"] $ \o -> do
      tag <- o .: "tag"
      case tag :: String of
        "Title" -> pure Title
        "Timeline" -> pure Timeline
        "Badge" -> pure Badge
        _ -> fail ("unknown affordance: " ++ tag)
    fieldRole = exact "FieldRole" ["recordType", "field", "role"] $ \o ->
      FieldRole <$> o .: "recordType" <*> o .: "field" <*> o .: "role"
    collectionDecl = exact "CollectionDecl" ["collection", "rootField", "references"] $ \o ->
      CollectionDecl <$> o .: "collection" <*> o .: "rootField" <*> (o .: "references" >>= mapM reference)
    reference = exact "Reference" ["field", "collection"] $ \o ->
      (,) <$> o .: "field" <*> o .: "collection"

exact :: String -> [Key] -> (Object -> Parser a) -> Value -> Parser a
exact label expected parse = withObject label $ \o -> do
  unless (sort (KeyMap.keys o) == sort expected) (fail (label ++ ": unexpected or missing fields"))
  parse o

evaluateMetadata
  :: (GuestCompilation :> es, GuestExecution :> es, Failure :> es)
  => GuestSources -> Eff es (Either [Diagnostic] SchemaMetadata)
evaluateMetadata sources = do
  compiled <- compileGuest sources
  case compiled of
    Left diagnostics -> pure (Left diagnostics)
    Right entry -> do
      (output, ProcessExit status diagnostics) <- executeCompiled entry Bytes.empty
      if status /= 0
        then raiseFailure (RuntimeUnavailable (ProcessDiagnostic WaitForExit
          ("metadata entry exited " ++ show status ++ ": " ++ show diagnostics)))
        else case decodeMetadata output of
          Left message -> raiseFailure (RuntimeUnavailable (ProcessDiagnostic ReadOutput
            ("invalid metadata response: " ++ message)))
          Right value -> pure (Right value)
