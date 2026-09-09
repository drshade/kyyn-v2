module Kyyn.Plumbing.Protocol.EvolutionRecord.Contract (snapshotShape, snapshotValue, restoreSnapshot) where

import Control.Monad (foldM)
import Data.Aeson (Value, object, (.=), toJSON, withObject, (.:))
import Data.Aeson.Types (Parser, parseJSON)
import Data.List (nub, elemIndex)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Types.SchemaMetadata

snapshotShape :: Shape
snapshotShape = Record [("fingerprint",text), ("types",List node), ("metadata",metadata)]
  where
    node = Union [("Text",Nothing), ("Integer",Nothing), ("Bool",Nothing),
      ("List",Just index), ("Optional",Just index),
      ("Data",Just (Record [("name",text),("arguments",List index),
        ("constructors",List (Record [("name",text), ("fields",List
          (Record [("name",Optional text),("type",index)]))]))]))]
    metadata = Record
      [("roles",List (Record [("name",text),("description",text),("affordance",Union
        [("Title",Nothing),("Timeline",Nothing),("Badge",Nothing)])])),
       ("fields",List (Record [("type",text),("field",text),("role",text)])),
       ("collections",List (Record [("name",text),("field",text),
         ("references",List (Record [("field",text),("collection",text)]))]))]

snapshotValue :: RootContract -> Value
snapshotValue contract = object ["fingerprint" .= contractFingerprint (contractId schema),
  "types" .= map node types, "metadata" .= metadata]
  where
    schema = rootSchema contract
    types = nub (ordered (rootType schema))
    reference t = case elemIndex t types of
      Just i -> toJSON (show i)
      Nothing -> error "Contract snapshot omitted a reachable type"
    node StringType = tagged "Text" Nothing
    node IntegerType = tagged "Integer" Nothing
    node BoolType = tagged "Bool" Nothing
    node (ListType item) = tagged "List" (Just (reference item))
    node (OptionalType item) = tagged "Optional" (Just (reference item))
    node (Algebraic name arguments constructors) = tagged "Data" (Just (object
      ["name" .= name, "arguments" .= map reference arguments,
       "constructors" .= [object ["name" .= n, "fields" .=
         [object ["name" .= optional (toJSON <$> label), "type" .= reference t] | (label,t) <- fields]]
         | Constructor n fields <- constructors]]))
    SchemaMetadata roles assignments collections = metadataOf schema
    metadata = object
      ["roles" .= [object ["name" .= name, "description" .= description,
        "affordance" .= tagged (show affordance) Nothing] | RoleDecl name description affordance <- roles],
       "fields" .= [object ["type" .= t,"field" .= field,"role" .= role] | FieldRole t field role <- assignments],
       "collections" .= [object ["name" .= name,"field" .= field,"references" .=
         [object ["field" .= f,"collection" .= c] | (f,c) <- references]]
         | CollectionDecl name field references <- collections]]

restoreSnapshot :: Value -> Parser (Either [Diagnostic] RootContract)
restoreSnapshot = withObject "Contract snapshot" $ \record -> do
  fingerprint <- record .: "fingerprint"
  nodes <- record .: "types" :: Parser [Value]
  types <- foldM (\previous value -> do
    next <- node previous value
    pure (previous ++ [next])) [] nodes
  root <- case reverse types of
    t : _ -> pure t
    [] -> fail "Contract snapshot has no root type"
  metadata <- record .: "metadata" >>= parseMetadata
  pure $ case checkContract root metadata >>= checkRootLayout of
    Right contract | contractFingerprint (contractId (rootSchema contract)) == fingerprint -> Right contract
    _ -> Left [errorDiagnostic "schema.stored-contract" "Stored contract cannot be reconstructed with its fingerprint by this kernel"]
  where
    reference previous value = do
      source <- parseJSON value
      case reads source of
        [(i,"")] | i >= (0 :: Integer), i < toInteger (length previous), show i == source ->
          pure (previous !! fromInteger i)
        _ -> fail "Type reference must identify an earlier declaration"
    node previous = withObject "Type declaration" $ \record -> do
      tag <- record .: "tag" :: Parser String
      case tag of
        "Text" -> pure StringType
        "Integer" -> pure IntegerType
        "Bool" -> pure BoolType
        "List" -> ListType <$> (record .: "value" >>= reference previous)
        "Optional" -> OptionalType <$> (record .: "value" >>= reference previous)
        "Data" -> record .: "value" >>= withObject "Data declaration" (\decl ->
          Algebraic <$> decl .: "name"
            <*> (decl .: "arguments" >>= traverse (reference previous))
            <*> (decl .: "constructors" >>= traverse (constructor previous)))
        _ -> fail "Unknown type declaration"
    constructor previous = withObject "Constructor" $ \record -> Constructor
      <$> record .: "name" <*> (record .: "fields" >>= traverse (withObject "Field" (\field ->
        (,) <$> (field .: "name" >>= optionalText) <*> (field .: "type" >>= reference previous))))

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

ordered :: DataType -> [DataType]
ordered t = (case t of
  ListType item -> ordered item
  OptionalType item -> ordered item
  Algebraic _ arguments constructors -> concatMap ordered
    (arguments ++ [field | Constructor _ fields <- constructors, (_,field) <- fields])
  _ -> []) ++ [t]

optionalText :: Value -> Parser (Maybe String)
optionalText = withObject "Optional field name" $ \record -> do
  tag <- record .: "tag" :: Parser String
  case tag of
    "None" -> pure Nothing
    "Some" -> Just <$> record .: "value"
    _ -> fail "Expected Some or None"

optional :: Maybe Value -> Value
optional Nothing = tagged "None" Nothing
optional (Just value) = tagged "Some" (Just value)

tagged :: String -> Maybe Value -> Value
tagged tag value = object (["tag" .= tag] ++ maybe [] (\v -> ["value" .= v]) value)

text, index :: Shape
text = Scalar TextScalar
index = Scalar IntegerScalar
