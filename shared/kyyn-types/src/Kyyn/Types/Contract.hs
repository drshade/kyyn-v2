{-# LANGUAGE DeriveAnyClass, DeriveGeneric, OverloadedStrings #-}
-- | Serializable descriptions and their one shared identity calculation.
module Kyyn.Types.Contract
  ( TypeIdentity(..), FieldStyle(..), ScalarKind(..), Description(..)
  , FieldDescription(..), CaseDescription(..), ContractId
  , contractIdentity, fingerprint, parseFingerprint, validateDescription
  , qualifiedTypeName
  ) where

import Control.DeepSeq (NFData)
import Control.Monad (unless)
import qualified Crypto.Hash.SHA256 as SHA256
import Data.Aeson (ToJSON(..), FromJSON(..), Value(..), encode, withArray)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.Foldable (toList)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Numeric (showHex, readHex)
import Text.Read (readMaybe)
import Kyyn.Types.SchemaMetadata

data TypeIdentity = TypeIdentity Text Text Text [TypeIdentity]
  deriving (Eq, Ord, Show, Generic, ToJSON, FromJSON, NFData)

data FieldStyle = NamedFields | PositionalFields
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data ScalarKind
  = TextScalar | BoolScalar | IntegerScalar | IntScalar Integer Integer
  | NaturalScalar | DecimalScalar Integer | DateScalar | InstantScalar
  | ProbabilityScalar | FactIdScalar | BlobRefScalar
  deriving (Eq, Show, Generic, NFData)

instance ToJSON ScalarKind where
  toJSON value = toJSON $ case value of
    TextScalar -> ["text"]
    BoolScalar -> ["bool"]
    IntegerScalar -> ["integer"]
    IntScalar lo hi -> ["bounded-integer", T.pack (show lo), T.pack (show hi)]
    NaturalScalar -> ["natural"]
    DecimalScalar resolution -> ["decimal", T.pack (show resolution)]
    DateScalar -> ["date"]
    InstantScalar -> ["instant"]
    ProbabilityScalar -> ["probability"]
    FactIdScalar -> ["fact-id"]
    BlobRefScalar -> ["blob-ref"]

instance FromJSON ScalarKind where
  parseJSON = withArray "scalar descriptor" $ \values -> case toList values of
    [String "text"] -> pure TextScalar
    [String "bool"] -> pure BoolScalar
    [String "integer"] -> pure IntegerScalar
    [String "bounded-integer",String lo,String hi] -> IntScalar <$> number lo <*> number hi
    [String "natural"] -> pure NaturalScalar
    [String "decimal",String resolution] -> DecimalScalar <$> number resolution
    [String "date"] -> pure DateScalar
    [String "instant"] -> pure InstantScalar
    [String "probability"] -> pure ProbabilityScalar
    [String "fact-id"] -> pure FactIdScalar
    [String "blob-ref"] -> pure BlobRefScalar
    _ -> fail "unsupported scalar descriptor"
    where
      number text = case readMaybe (T.unpack text) of
        Just n | T.pack (show (n :: Integer)) == text -> pure n
        _ -> fail "expected a canonical integer in the scalar descriptor"

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
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data FieldDescription = FieldDescription Text Text Description
  deriving (Eq, Show, Generic, ToJSON, FromJSON)
data CaseDescription = CaseDescription Text Text FieldStyle [FieldDescription]
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

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
