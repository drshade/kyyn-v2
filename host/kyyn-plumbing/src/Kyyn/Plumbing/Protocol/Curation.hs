module Kyyn.Plumbing.Protocol.Curation (curationShape, curationValue, parseCuration) where

import Control.Monad (unless)
import Data.Aeson (Value, Object, object, (.=), (.:), withObject)
import Data.Aeson.Types (Parser)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import Data.List (sort)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Types.Curation
import Kyyn.Types.Evidence (EvidenceId(..))

curationShape :: Shape
curationShape = Optional (Record [("recipe",text),("handled",List acknowledgement)])
  where
    text = Scalar TextScalar
    scope = Record [("plugin",text),("instance",text),("fetch",text)]
    acknowledgement = Union [("EntireBatch",Just scope),
      ("IndividualRecords",Just (Record [("scope",scope),("ids",List text)]))]

curationValue :: Maybe Curation -> Value
curationValue Nothing = tagged "None" Nothing
curationValue (Just (Curation (RecipeId recipe) handled)) = tagged "Some" (Just
  (object ["recipe" .= recipe,"handled" .= map acknowledgement handled]))
  where
    scope (EvidenceScope plugin instanceName fetch) = object
      ["plugin" .= plugin,"instance" .= instanceName,"fetch" .= fetch]
    acknowledgement (EntireBatch selected) = tagged "EntireBatch" (Just (scope selected))
    acknowledgement (IndividualRecords selected ids) = tagged "IndividualRecords" (Just
      (object ["scope" .= scope selected,"ids" .= [item | EvidenceId item <- ids]]))

parseCuration :: Value -> Parser (Maybe Curation)
parseCuration = withObject "Optional curation" $ \fields -> do
  tag <- fields .: "tag"
  case tag :: String of
    "None" -> fieldsAre ["tag"] fields >> pure Nothing
    "Some" -> do
      fieldsAre ["tag","value"] fields
      Just <$> (fields .: "value" >>= exact ["recipe","handled"] (\entry ->
        Curation <$> (RecipeId <$> entry .: "recipe") <*> (entry .: "handled" >>= traverse acknowledgement)))
    _ -> fail "Expected Some or None curation"
  where
    scope = exact ["plugin","instance","fetch"] $ \fields -> EvidenceScope
      <$> fields .: "plugin" <*> fields .: "instance" <*> fields .: "fetch"
    acknowledgement = exact ["tag","value"] $ \fields -> do
      tag <- fields .: "tag"
      value <- fields .: "value"
      case tag :: String of
        "EntireBatch" -> EntireBatch <$> scope value
        "IndividualRecords" -> exact ["scope","ids"] (\entry -> IndividualRecords
          <$> (entry .: "scope" >>= scope) <*> (map EvidenceId <$> entry .: "ids")) value
        _ -> fail "Unknown acknowledgement"

tagged :: String -> Maybe Value -> Value
tagged tag value = object (["tag" .= tag] ++ maybe [] (\v -> ["value" .= v]) value)

exact :: [Key] -> (Object -> Parser a) -> Value -> Parser a
exact keys parse = withObject "Curation" $ \fields -> fieldsAre keys fields >> parse fields

fieldsAre :: [Key] -> Object -> Parser ()
fieldsAre keys fields = unless (sort keys == sort (Keys.keys fields))
  (fail "Unexpected or missing curation fields")
