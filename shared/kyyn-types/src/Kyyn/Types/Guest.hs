{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable, OverloadedStrings #-}
module Kyyn.Types.Guest
  ( GuestDescription(..), DescribedContract(..), EntryDescription, GuestEntry(..)
  , QueryContracts(..), ExportDescription(..), ExportKind(..)
  , protocolIdentity, describeContract
  ) where

import Data.Aeson (ToJSON(..), FromJSON(..), Value(..), object, (.=), (.:), withObject, withText)
import Data.Text (Text)
import Kyyn.Types.Contract
import Kyyn.Types.Json (exactObject)
import Kyyn.Types.SchemaMetadata

-- Protocol equality selects the current interface; there is no negotiation.
protocolIdentity :: Text
protocolIdentity = "kyyn-guest-1"

data DescribedContract = DescribedContract
  { structure :: Description, metadata :: SchemaMetadata, identity :: Text
  , loadedSources :: [Text]
  } deriving (Eq, Show)

-- The same closed entry shape carries descriptions on the wire and checked
-- contracts in the host. No optional or string-indexed bag of contracts exists.
data GuestEntry contract
  = ValidatorEntry { entryName :: Text, validatorContract :: contract }
  | QueryEntry { entryName :: Text, queryContracts :: QueryContracts contract }
  | ContractEntry { entryName :: Text, describedContract :: contract }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data QueryContracts contract = QueryContracts
  { rootContract :: contract, argumentContract :: contract, resultContract :: contract }
  deriving (Eq, Show, Functor, Foldable, Traversable)

type EntryDescription = GuestEntry DescribedContract

data ExportKind = ExportType | ExportConstructor | ExportValue | ExportCoercion deriving (Eq, Ord, Show)
data ExportDescription = ExportDescription
  { exportModule :: Text, exportName :: Text, exportSignature :: Text, exportSource :: Text, exportKind :: ExportKind
  } deriving (Eq, Show)

data GuestDescription = GuestDescription
  { protocol :: Text, entries :: [EntryDescription], exports :: [ExportDescription]
  } deriving (Eq, Show)

instance ToJSON DescribedContract where
  toJSON (DescribedContract description annotations digest sources) = object
    ["structure" .= description,"metadata" .= annotations,"identity" .= digest,"loadedSources" .= sources]
instance FromJSON DescribedContract where
  parseJSON = exactObject "described contract" ["structure","metadata","identity","loadedSources"] $ \fields ->
    DescribedContract <$> fields .: "structure" <*> fields .: "metadata" <*> fields .: "identity" <*> fields .: "loadedSources"

instance ToJSON contract => ToJSON (GuestEntry contract) where
  toJSON (ValidatorEntry name root) = object ["entryName" .= name,"kind" .= String "validator","root" .= root]
  toJSON (QueryEntry name (QueryContracts root arguments result)) = object
    ["entryName" .= name,"kind" .= String "query","root" .= root,"arguments" .= arguments,"result" .= result]
  toJSON (ContractEntry name value) = object ["entryName" .= name,"kind" .= String "contract","value" .= value]
instance FromJSON contract => FromJSON (GuestEntry contract) where
  parseJSON value = withObject "guest entry" (\fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "validator" -> exactObject "validator entry" ["entryName","kind","root"]
        (\entry -> ValidatorEntry <$> entry .: "entryName" <*> entry .: "root") value
      "query" -> exactObject "query entry" ["entryName","kind","root","arguments","result"]
        (\entry -> QueryEntry <$> entry .: "entryName" <*> (QueryContracts
          <$> entry .: "root" <*> entry .: "arguments" <*> entry .: "result")) value
      "contract" -> exactObject "contract entry" ["entryName","kind","value"]
        (\entry -> ContractEntry <$> entry .: "entryName" <*> entry .: "value") value
      _ -> fail "Unknown guest entry kind") value

instance ToJSON ExportKind where
  toJSON kind = String (case kind of
    ExportType -> "type"; ExportConstructor -> "constructor"; ExportValue -> "value"; ExportCoercion -> "coercion")
instance FromJSON ExportKind where
  parseJSON = withText "export kind" $ \kind -> case kind of
    "type" -> pure ExportType
    "constructor" -> pure ExportConstructor
    "value" -> pure ExportValue
    "coercion" -> pure ExportCoercion
    _ -> fail "Unknown export kind"

instance ToJSON ExportDescription where
  toJSON (ExportDescription moduleName name signature source kind) = object
    ["exportModule" .= moduleName,"exportName" .= name,"exportSignature" .= signature,
     "exportSource" .= source,"exportKind" .= kind]
instance FromJSON ExportDescription where
  parseJSON = exactObject "export" ["exportModule","exportName","exportSignature","exportSource","exportKind"] $ \fields ->
    ExportDescription <$> fields .: "exportModule" <*> fields .: "exportName" <*> fields .: "exportSignature"
      <*> fields .: "exportSource" <*> fields .: "exportKind"

instance ToJSON GuestDescription where
  toJSON (GuestDescription selectedProtocol selectedEntries selectedExports) = object
    ["protocol" .= selectedProtocol,"entries" .= selectedEntries,"exports" .= selectedExports]
instance FromJSON GuestDescription where
  parseJSON = exactObject "guest description" ["protocol","entries","exports"] $ \fields ->
    GuestDescription <$> fields .: "protocol" <*> fields .: "entries" <*> fields .: "exports"

describeContract :: Description -> SchemaMetadata -> [Text] -> DescribedContract
describeContract description annotations sources = DescribedContract description annotations
  (fingerprint (contractIdentity description annotations)) sources
