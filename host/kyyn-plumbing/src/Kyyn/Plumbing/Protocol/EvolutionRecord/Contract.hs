module Kyyn.Plumbing.Protocol.EvolutionRecord.Contract
  ( snapshotShape, snapshotValue, restoreSnapshot, checkedSnapshotValue, restoreCheckedSnapshot ) where

import Data.Aeson (Value, object, (.=), withObject, (.:))
import Data.Aeson.Types (Parser)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Types.SchemaMetadata
import Kyyn.Plumbing.Protocol.DataType (dataTypeShape, dataTypeValue, parseDataType)

snapshotShape :: Shape
snapshotShape = Record [("fingerprint",text), ("types",dataTypeShape), ("metadata",metadata)]
  where
    metadata = Record
      [("roles",List (Record [("name",text),("description",text),("affordance",Union
        [("Title",Nothing),("Timeline",Nothing),("Badge",Nothing)])])),
       ("fields",List (Record [("type",text),("field",text),("role",text)])),
       ("collections",List (Record [("name",text),("field",text),
         ("references",List (Record [("field",text),("collection",text)]))]))]

snapshotValue :: RootContract -> Value
snapshotValue = checkedSnapshotValue . rootSchema

checkedSnapshotValue :: CheckedContract -> Value
checkedSnapshotValue schema = object ["fingerprint" .= contractFingerprint (contractId schema),
  "types" .= dataTypeValue (rootType schema), "metadata" .= metadata]
  where
    SchemaMetadata roles assignments collections = metadataOf schema
    metadata = object
      ["roles" .= [object ["name" .= name, "description" .= description,
        "affordance" .= tagged (affordanceName affordance) Nothing] | RoleDecl name description affordance <- roles],
       "fields" .= [object ["type" .= t,"field" .= field,"role" .= role] | FieldRole t field role <- assignments],
       "collections" .= [object ["name" .= name,"field" .= field,"references" .=
         [object ["field" .= f,"collection" .= c] | (f,c) <- references]]
         | CollectionDecl name field references <- collections]]

restoreSnapshot :: Value -> Parser (Either [Diagnostic] RootContract)
restoreSnapshot value = fmap (>>= checkRootLayout) (restoreCheckedSnapshot value)

restoreCheckedSnapshot :: Value -> Parser (Either [Diagnostic] CheckedContract)
restoreCheckedSnapshot = withObject "Contract snapshot" $ \record -> do
  fingerprint <- record .: "fingerprint"
  root <- record .: "types" >>= parseDataType
  metadata <- record .: "metadata" >>= parseMetadata
  pure $ case checkContract root metadata of
    Right contract | contractFingerprint (contractId contract) == fingerprint -> Right contract
    _ -> Left [errorDiagnostic "schema.stored-contract" "Stored contract cannot be reconstructed with its fingerprint by this kernel"]

parseMetadata :: Value -> Parser SchemaMetadata
parseMetadata = withObject "Schema metadata" $ \record -> SchemaMetadata
  <$> (record .: "roles" >>= traverse (withObject "Role" (\role -> RoleDecl
    <$> role .: "name" <*> role .: "description" <*> (role .: "affordance" >>= affordance))))
  <*> (record .: "fields" >>= traverse (withObject "Field role" (\field -> FieldRole
    <$> field .: "type" <*> field .: "field" <*> field .: "role")))
  <*> (record .: "collections" >>= traverse (withObject "Collection" (\collection -> CollectionDecl
    <$> collection .: "name" <*> collection .: "field"
    <*> (collection .: "references" >>= traverse (withObject "Reference" (\ref ->
      (,) <$> ref .: "field" <*> ref .: "collection"))))))
  where
    affordance = withObject "Affordance" $ \record -> do
      name <- record .: "tag" :: Parser String
      case name of
        "Title" -> pure Title
        "Timeline" -> pure Timeline
        "Badge" -> pure Badge
        _ -> fail "Unknown affordance"

affordanceName :: Affordance -> String
affordanceName Title = "Title"
affordanceName Timeline = "Timeline"
affordanceName Badge = "Badge"

tagged :: String -> Maybe Value -> Value
tagged tag value = object (["tag" .= tag] ++ maybe [] (\v -> ["value" .= v]) value)

text :: Shape
text = Scalar TextScalar
