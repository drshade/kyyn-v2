{-# LANGUAGE DeriveAnyClass, DeriveGeneric, OverloadedStrings #-}
-- | Serializable descriptions and their one shared identity calculation.
module Kyyn.Types.Contract
  ( TypeIdentity(..), FieldStyle(..), ScalarKind(..), Description(..)
  , FieldDescription(..), CaseDescription(..), ContractId
  , contractIdentity, fingerprint, parseFingerprint, validateDescription
  , qualifiedTypeName, descriptionTypeName, descriptionValue, parseDescription
  ) where

import Control.DeepSeq (NFData)
import Control.Monad (unless, foldM)
import qualified Crypto.Hash.SHA256 as SHA256
import Data.Aeson (ToJSON(..), FromJSON(..), Value(..), encode, object, (.=), withObject, (.:))
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.List (nub, elemIndex)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Numeric (showHex, readHex)
import Data.Aeson.Types (Parser)
import Kyyn.Types.Json (exactObject)
import Kyyn.Types.Contract.ScalarKind (ScalarKind(..))
import Kyyn.Types.SchemaMetadata

data TypeIdentity = TypeIdentity Text Text Text [TypeIdentity]
  deriving (Eq, Ord, Show, Generic, NFData)

data FieldStyle = NamedFields | PositionalFields
  deriving (Eq, Show, Generic)


data Description
  = ScalarDescription TypeIdentity ScalarKind Text [(Text,Text)]
  | NamedDescription TypeIdentity Description
  | RecordDescription Text FieldStyle [FieldDescription]
  | SumDescription [CaseDescription]
  | ListDescription Description
  | OptionalDescription Description
  | UnitDescription
  | CheckedDescription Text Description
  | DocumentedDescription Text Description
  deriving (Eq, Show, Generic)

data FieldDescription = FieldDescription Text Text Description
  deriving (Eq, Show, Generic)
data CaseDescription = CaseDescription Text Text FieldStyle [FieldDescription]
  deriving (Eq, Show, Generic)

newtype ContractId = ContractId Bytes.ByteString deriving (Eq, Ord, Show)

-- Fixed tags make identity independent of Haskell constructor names and Aeson's
-- generic transport encoding. Declaration order remains significant.
contractIdentity :: Description -> SchemaMetadata -> ContractId
contractIdentity description metadata = ContractId . SHA256.hash . Lazy.toStrict . encode $
  toJSON [String "kyyn-contract-1", canonicalDescription description, canonicalMetadata metadata]

canonicalType :: TypeIdentity -> Value
canonicalType (TypeIdentity packageName moduleName name args) =
  toJSON [String packageName, String moduleName, String name, toJSON (map canonicalType args)]

canonicalDescription :: Description -> Value
canonicalDescription description = toJSON $ case description of
  ScalarDescription identity kind name parameters ->
    [String "scalar", canonicalType identity, toJSON kind, String name, toJSON parameters]
  NamedDescription identity inner -> [String "named", canonicalType identity, canonicalDescription inner]
  RecordDescription name style fields -> [String "record", String name, styleValue style, toJSON (map fieldValue fields)]
  SumDescription cases -> [String "sum", toJSON (map caseValue cases)]
  ListDescription inner -> [String "list", canonicalDescription inner]
  OptionalDescription inner -> [String "optional", canonicalDescription inner]
  UnitDescription -> [String "unit"]
  CheckedDescription label inner -> [String "checked", String label, canonicalDescription inner]
  DocumentedDescription doc inner -> [String "documented", String doc, canonicalDescription inner]
  where
    styleValue NamedFields = String "named"
    styleValue PositionalFields = String "positional"
    fieldValue (FieldDescription name doc inner) = toJSON [String name, String doc, canonicalDescription inner]
    caseValue (CaseDescription name doc style fields) =
      toJSON [String name, String doc, styleValue style, toJSON (map fieldValue fields)]

canonicalMetadata :: SchemaMetadata -> Value
canonicalMetadata (SchemaMetadata roles fields collections) = toJSON
  [String "metadata",
   toJSON [toJSON [String name, String doc, affordanceValue affordance] | RoleDecl name doc affordance <- roles],
   toJSON [toJSON [record,field,role] | FieldRole record field role <- fields],
   toJSON [toJSON [String name,String field,toJSON references] | CollectionDecl name field references <- collections]]
  where
    affordanceValue Title = String "title"
    affordanceValue Timeline = String "timeline"
    affordanceValue Badge = String "badge"

fingerprint :: ContractId -> Text
fingerprint (ContractId bytes) = T.pack (concatMap hex (Bytes.unpack bytes))
  where hex byte = let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits

parseFingerprint :: Text -> Either Text ContractId
parseFingerprint text
  | T.length text == 64 && T.all (`elem` ("0123456789abcdef" :: String)) text =
      ContractId . Bytes.pack <$> pairs (T.unpack text)
  | otherwise = Left "expected a 64-character lowercase hexadecimal contract identity"
  where
    pairs [] = Right []
    pairs (a:b:rest) = case readHex [a,b] of
      [(byte,"")] -> (byte:) <$> pairs rest
      _ -> Left "invalid contract identity"
    pairs _ = Left "invalid contract identity"

qualifiedTypeName :: TypeIdentity -> Text
qualifiedTypeName (TypeIdentity _ moduleName name _) = moduleName <> "." <> name

validateDescription :: Description -> Either Text ()
validateDescription description = case description of
  ScalarDescription identity kind name parameters -> do
    validType identity
    unless (not (T.null name)) (Left "empty scalar identity")
    unique "scalar parameter" (map fst parameters)
    case kind of
      DecimalScalar resolution -> unless (resolution `elem` [1,10,100,1000,1000000,1000000000,1000000000000]) (Left "unsupported fixed-point resolution")
      IntScalar lo hi -> unless (lo <= hi) (Left "invalid bounded integer range")
      _ -> Right ()
  NamedDescription identity inner -> validType identity >> validateDescription inner
  RecordDescription _ style fields -> validFields style fields
  SumDescription cases -> do
    unless (not (null cases)) (Left "empty sums are unsupported")
    unique "constructor" [name | CaseDescription name _ _ _ <- cases]
    mapM_ (\(CaseDescription _ _ style fields) -> validFields style fields) cases
  ListDescription inner -> validateDescription inner
  OptionalDescription inner -> validateDescription inner
  UnitDescription -> Right ()
  CheckedDescription _ inner -> validateDescription inner
  DocumentedDescription _ inner -> validateDescription inner
  where
    validType (TypeIdentity packageName moduleName name args) = do
      unless (all (not . T.null) [packageName,moduleName,name]) (Left "incomplete resolved type identity")
      mapM_ validType args
    validFields style fields = do
      unique "field" [name | FieldDescription name _ _ <- fields]
      unless (style == NamedFields || length fields <= 1) (Left "multiple positional fields are unsupported")
      mapM_ (\(FieldDescription _ _ inner) -> validateDescription inner) fields
    unique label names = do
      unless (all (not . T.null) names) (Left ("empty " <> label <> " name"))
      unless (length names == length (nub names)) (Left ("duplicate " <> label <> " names"))

instance ToJSON Description where
  toJSON = descriptionValue
instance FromJSON Description where
  parseJSON = parseDescription

descriptionValue :: Description -> Value
descriptionValue root = object ["types" .= map typeValue types,"nodes" .= map nodeValue nodes]
  where
    nodes = nub (ordered root)
    types = nub (concatMap identities nodes)
    typeReference = reference types
    nodeReference = reference nodes
    typeValue (TypeIdentity packageName moduleName name arguments) = object
      ["package" .= packageName,"module" .= moduleName,"name" .= name,"arguments" .= map typeReference arguments]
    fieldValue (FieldDescription name doc inner) = object
      ["name" .= name,"doc" .= doc,"inner" .= nodeReference inner]
    caseValue (CaseDescription name doc style fields) = object
      ["name" .= name,"doc" .= doc,"style" .= styleValue style,"fields" .= map fieldValue fields]
    styleValue NamedFields = tagged "Named" Nothing
    styleValue PositionalFields = tagged "Positional" Nothing
    annotation text inner = object ["text" .= text,"inner" .= nodeReference inner]
    nodeValue description = case description of
      ScalarDescription identity kind name parameters -> tagged "Scalar" (Just (object
        ["type" .= typeReference identity,"kind" .= kind,"name" .= name,
         "parameters" .= [object ["name" .= key,"value" .= value] | (key,value) <- parameters]]))
      NamedDescription identity inner -> tagged "Named" (Just (object
        ["type" .= typeReference identity,"inner" .= nodeReference inner]))
      RecordDescription name style fields -> tagged "Record" (Just (object
        ["name" .= name,"style" .= styleValue style,"fields" .= map fieldValue fields]))
      SumDescription cases -> tagged "Sum" (Just (toJSON (map caseValue cases)))
      ListDescription inner -> tagged "List" (Just (nodeReference inner))
      OptionalDescription inner -> tagged "Optional" (Just (nodeReference inner))
      UnitDescription -> tagged "Unit" Nothing
      CheckedDescription label inner -> tagged "Checked" (Just (annotation label inner))
      DocumentedDescription doc inner -> tagged "Documented" (Just (annotation doc inner))

parseDescription :: Value -> Parser Description
parseDescription = exactObject "contract description" ["types","nodes"] $ \document -> do
  typeNodes <- document .: "types" :: Parser [Value]
  types <- foldM (\previous node -> do
    next <- exactObject "resolved type" ["package","module","name","arguments"] (\fields -> TypeIdentity
      <$> fields .: "package" <*> fields .: "module" <*> fields .: "name"
      <*> (fields .: "arguments" >>= traverse (resolve previous))) node
    pure (previous ++ [next])) [] typeNodes
  input <- document .: "nodes" :: Parser [Value]
  nodes <- foldM (\previous node -> do
    next <- parseNode types previous node
    pure (previous ++ [next])) [] input
  case reverse nodes of
    root:_ -> either (fail . T.unpack) (const (pure root)) (validateDescription root)
    [] -> fail "No root contract description"
  where
    parseNode types previous value = do
      record <- withObject "description node" pure value
      tag <- record .: "tag" :: Parser Text
      _ <- exactObject "description node" (if tag == "Unit" then ["tag"] else ["tag","value"]) pure value
      let body action = record .: "value" >>= action
          fieldsOf = traverse (exactObject "field" ["name","doc","inner"] (\field -> FieldDescription
            <$> field .: "name" <*> field .: "doc" <*> (field .: "inner" >>= resolve previous)))
          annotation constructor = body $ exactObject "annotation" ["text","inner"] $ \fields ->
            constructor <$> fields .: "text" <*> (fields .: "inner" >>= resolve previous)
      case tag of
        "Scalar" -> body $ exactObject "scalar" ["type","kind","name","parameters"] $ \fields -> ScalarDescription
          <$> (fields .: "type" >>= resolve types) <*> fields .: "kind" <*> fields .: "name"
          <*> (fields .: "parameters" >>= traverse (exactObject "parameter" ["name","value"] (\pair -> (,)
            <$> pair .: "name" <*> pair .: "value")))
        "Named" -> body $ exactObject "named type" ["type","inner"] $ \fields -> NamedDescription
          <$> (fields .: "type" >>= resolve types) <*> (fields .: "inner" >>= resolve previous)
        "Record" -> body $ exactObject "record" ["name","style","fields"] $ \fields -> RecordDescription
          <$> fields .: "name" <*> (fields .: "style" >>= parseStyle) <*> (fields .: "fields" >>= fieldsOf)
        "Sum" -> body $ \casesValue -> SumDescription <$> (parseJSON casesValue >>= traverse
          (exactObject "case" ["name","doc","style","fields"] (\fields -> CaseDescription
            <$> fields .: "name" <*> fields .: "doc" <*> (fields .: "style" >>= parseStyle)
            <*> (fields .: "fields" >>= fieldsOf))))
        "List" -> body (fmap ListDescription . resolve previous)
        "Optional" -> body (fmap OptionalDescription . resolve previous)
        "Unit" -> pure UnitDescription
        "Checked" -> annotation CheckedDescription
        "Documented" -> annotation DocumentedDescription
        _ -> fail "Unknown contract description node"
    parseStyle = exactObject "field style" ["tag"] $ \fields -> do
      tag <- fields .: "tag" :: Parser Text
      case tag of
        "Named" -> pure NamedFields
        "Positional" -> pure PositionalFields
        _ -> fail "Unknown field style"

reference :: Eq a => [a] -> a -> Value
reference values value = case elemIndex value values of
  Just index -> toJSON (show index)
  Nothing -> error "Description encoding omitted a dependency"

resolve :: [a] -> Value -> Parser a
resolve previous value = do
  source <- parseJSON value
  case reads source of
    [(index,"")] | index >= (0 :: Integer), index < toInteger (length previous), show index == source ->
      pure (previous !! fromInteger index)
    _ -> fail "Description reference must identify an earlier node"

ordered :: Description -> [Description]
ordered description = concatMap ordered (children description) ++ [description]
  where
    children (NamedDescription _ inner) = [inner]
    children (RecordDescription _ _ fields) = [inner | FieldDescription _ _ inner <- fields]
    children (SumDescription cases) = [inner | CaseDescription _ _ _ fields <- cases, FieldDescription _ _ inner <- fields]
    children (ListDescription inner) = [inner]
    children (OptionalDescription inner) = [inner]
    children (CheckedDescription _ inner) = [inner]
    children (DocumentedDescription _ inner) = [inner]
    children _ = []

identities :: Description -> [TypeIdentity]
identities (ScalarDescription identity _ _ _) = typeTree identity
identities (NamedDescription identity _) = typeTree identity
identities _ = []

typeTree :: TypeIdentity -> [TypeIdentity]
typeTree identity@(TypeIdentity _ _ _ arguments) = concatMap typeTree arguments ++ [identity]

tagged :: Text -> Maybe Value -> Value
tagged tag value = object (["tag" .= tag] ++ maybe [] (\v -> ["value" .= v]) value)

-- Stable source-facing state name shared by generated RecipeType handles and
-- host persistence. It is descriptive data, never parsed into compiler types.
descriptionTypeName :: Description -> Either Text Text
descriptionTypeName description = case description of
  ScalarDescription identity kind _ _ -> Right (case kind of
    TextScalar -> "Data.Text.Text"
    IntegerScalar -> "Integer"
    BoolScalar -> "Bool"
    ProbabilityScalar -> "Agentic.Questions.Probability"
    FactIdScalar -> "Kyyn.Types.Fact.FactId"
    _ -> applied identity)
  NamedDescription identity inner | nominal inner -> Right (applied identity)
                                  | otherwise -> descriptionTypeName inner
  ListDescription inner -> (\name -> "[" <> name <> "]") <$> descriptionTypeName inner
  OptionalDescription inner -> (\name -> "(Maybe " <> name <> ")") <$> descriptionTypeName inner
  UnitDescription -> Right "()"
  CheckedDescription _ inner -> descriptionTypeName inner
  DocumentedDescription _ inner -> descriptionTypeName inner
  _ -> Left "Recipe state contract has no named type identity"
  where
    applied identity@(TypeIdentity _ _ _ arguments)
      | null arguments = qualifiedTypeName identity
      | otherwise = "(" <> T.unwords (qualifiedTypeName identity : map applied arguments) <> ")"
    nominal (RecordDescription _ _ _) = True
    nominal (SumDescription _) = True
    nominal (CheckedDescription _ inner) = nominal inner
    nominal (DocumentedDescription _ inner) = nominal inner
    nominal _ = False
