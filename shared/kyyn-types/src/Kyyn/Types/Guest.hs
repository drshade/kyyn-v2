{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable, OverloadedStrings #-}
module Kyyn.Types.Guest
  ( AcquisitionInvocation(..), AcquisitionContext(..), ConnectorIdentity(..), AcquisitionContracts(..)
  , GuestRequest(..), CapturedInvocation(..), GuestDescription(..), DescribedContract(..), EntryDescription, GuestEntry(..)
  , QueryContracts(..), CapturedContracts(..), CapturedMethodIdentity(..), ModuleDescription(..), ExportDescription(..), ExportKind(..)
  , protocolIdentity, describeContract
  ) where

import Data.Aeson (ToJSON(..), FromJSON(..), Value(..), object, (.=), (.:), withObject, withText)
import Data.Text (Text)
import Kyyn.Types.Contract
import Kyyn.Types.Json (exactObject, optionalValue, parseOptionalValue)
import Kyyn.Types.SchemaMetadata

-- One request codec is used by the host and the executable it describes.
data GuestRequest = Describe | Invoke Text Value deriving (Eq, Show)
data CapturedInvocation = CapturedInvocation
  { capturedArguments :: Value, capturedSnapshot :: Text } deriving (Eq, Show)

instance ToJSON GuestRequest where
  toJSON Describe = object ["operation" .= String "describe"]
  toJSON (Invoke entry argument) = object
    ["operation" .= String "invoke","entry" .= entry,"argument" .= argument]
instance FromJSON GuestRequest where
  parseJSON value = withObject "guest request" (\fields -> do
    operation <- fields .: "operation"
    case operation :: Text of
      "describe" -> exactObject "describe request" ["operation"] (const (pure Describe)) value
      "invoke" -> exactObject "invoke request" ["operation","entry","argument"]
        (\request -> Invoke <$> request .: "entry" <*> request .: "argument") value
      _ -> fail "Unknown guest operation") value

instance ToJSON CapturedInvocation where
  toJSON (CapturedInvocation arguments snapshot) = object ["arguments" .= arguments,"snapshot" .= snapshot]
instance FromJSON CapturedInvocation where
  parseJSON = exactObject "captured invocation" ["arguments","snapshot"] $ \fields ->
    CapturedInvocation <$> fields .: "arguments" <*> fields .: "snapshot"

data ConnectorIdentity = ConnectorIdentity
  { connectorPlugin :: Text, connectorType :: Text } deriving (Eq, Show)

data AcquisitionContext = AcquisitionContext
  { acquisitionStartedAt :: Text, acquisitionPriorPosition :: Maybe Value } deriving (Eq, Show)

data AcquisitionInvocation = AcquisitionInvocation
  { acquisitionConfig :: Value, acquisitionOptions :: Maybe Value
  , acquisitionContext :: Maybe AcquisitionContext, acquisitionSnapshot :: Text
  , acquisitionConcurrency :: Int } deriving (Eq, Show)

instance ToJSON ConnectorIdentity where
  toJSON (ConnectorIdentity plugin connector) = object ["plugin" .= plugin,"connector" .= connector]
instance FromJSON ConnectorIdentity where
  parseJSON = exactObject "connector identity" ["plugin","connector"] $ \fields ->
    ConnectorIdentity <$> fields .: "plugin" <*> fields .: "connector"
instance ToJSON AcquisitionContext where
  toJSON (AcquisitionContext startedAt prior) = object
    ["startedAt" .= startedAt,"priorPosition" .= optionalValue prior]
instance FromJSON AcquisitionContext where
  parseJSON = exactObject "acquisition context" ["startedAt","priorPosition"] $ \fields ->
    AcquisitionContext <$> fields .: "startedAt" <*> (fields .: "priorPosition" >>= parseOptionalValue)
instance ToJSON AcquisitionInvocation where
  toJSON (AcquisitionInvocation config options context snapshot width) = object
    ["config" .= config,"options" .= optionalValue options,"context" .= optionalValue context,
     "snapshot" .= snapshot,"concurrency" .= show width]
instance FromJSON AcquisitionInvocation where
  parseJSON = exactObject "acquisition invocation" ["config","options","context","snapshot","concurrency"] $ \fields -> do
    width <- fields .: "concurrency"
    selected <- maybe (fail "Host concurrency must be an integer string from 1 to 8") pure
      (lookup width [(show n,n) | n <- [1..8]])
    AcquisitionInvocation <$> fields .: "config" <*> (fields .: "options" >>= parseOptionalValue)
      <*> (fields .: "context" >>= parseOptionalValue) <*> fields .: "snapshot" <*> pure selected

-- State and report always occur together; optional fetch options are independent.
data AcquisitionContracts contract
  = StatelessContracts contract (Maybe contract) contract
  | StatefulContracts contract (Maybe contract) contract contract contract
  deriving (Eq, Show, Functor, Foldable, Traversable)

instance ToJSON contract => ToJSON (AcquisitionContracts contract) where
  toJSON (StatelessContracts config options payload) = object
    ["kind" .= String "stateless","config" .= config,"options" .= optionalValue options,"payload" .= payload]
  toJSON (StatefulContracts config options payload position report) = object
    ["kind" .= String "stateful","config" .= config,"options" .= optionalValue options,"payload" .= payload,
     "position" .= position,"report" .= report]
instance FromJSON contract => FromJSON (AcquisitionContracts contract) where
  parseJSON value = withObject "acquisition contracts" (\fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "stateless" -> exactObject "stateless contracts" ["kind","config","options","payload"]
        (\entry -> StatelessContracts <$> entry .: "config" <*> (entry .: "options" >>= parseOptionalValue)
          <*> entry .: "payload") value
      "stateful" -> exactObject "stateful contracts" ["kind","config","options","payload","position","report"]
        (\entry -> StatefulContracts <$> entry .: "config" <*> (entry .: "options" >>= parseOptionalValue)
          <*> entry .: "payload" <*> entry .: "position" <*> entry .: "report") value
      _ -> fail "Unknown acquisition shape") value

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
  | AcquisitionEntry { entryName :: Text, acquisitionConnector :: ConnectorIdentity, acquisitionContracts :: AcquisitionContracts contract }
  | CapturedReadEntry { entryName :: Text, capturedMethod :: CapturedMethodIdentity, capturedContracts :: CapturedContracts contract }
  | ContractEntry { entryName :: Text, describedContract :: contract }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data QueryContracts contract = QueryContracts
  { rootContract :: contract, argumentContract :: contract, resultContract :: contract }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data CapturedMethodIdentity = CapturedMethodIdentity
  { pluginName :: Text, connectorName :: Text, methodName :: Text, methodDescription :: Text }
  deriving (Eq, Show)

data CapturedContracts contract = CapturedContracts
  { inputContract :: contract, payloadContract :: contract, outputContract :: contract }
  deriving (Eq, Show, Functor, Foldable, Traversable)

instance ToJSON CapturedMethodIdentity where
  toJSON (CapturedMethodIdentity plugin connector method description) = object
    ["plugin" .= plugin,"connector" .= connector,"method" .= method,"description" .= description]
instance FromJSON CapturedMethodIdentity where
  parseJSON = exactObject "captured method" ["plugin","connector","method","description"] $ \fields ->
    CapturedMethodIdentity <$> fields .: "plugin" <*> fields .: "connector" <*> fields .: "method" <*> fields .: "description"

type EntryDescription = GuestEntry DescribedContract

data ExportKind = ExportType | ExportConstructor | ExportValue | ExportCoercion deriving (Eq, Ord, Show)
data ExportDescription = ExportDescription
  { exportName :: Text, exportSignature :: Text, exportOrigin :: Text
  , exportDocumentation :: Maybe Text, exportKind :: ExportKind
  } deriving (Eq, Show)

data ModuleDescription = ModuleDescription
  { moduleName :: Text, moduleSource :: Text, moduleDocumentation :: Maybe Text
  , moduleInstances :: [Text], moduleExports :: [ExportDescription]
  } deriving (Eq, Show)

data GuestDescription = GuestDescription
  { protocol :: Text, entries :: [EntryDescription], modules :: [ModuleDescription]
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
  toJSON (AcquisitionEntry name connector contracts) = object
    ["entryName" .= name,"kind" .= String "acquisition","connector" .= connector,"contracts" .= contracts]
  toJSON (CapturedReadEntry name method (CapturedContracts arguments payload result)) = object
    ["entryName" .= name,"kind" .= String "capturedRead","method" .= method,
     "arguments" .= arguments,"payload" .= payload,"result" .= result]
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
      "acquisition" -> exactObject "acquisition entry" ["entryName","kind","connector","contracts"]
        (\entry -> AcquisitionEntry <$> entry .: "entryName" <*> entry .: "connector" <*> entry .: "contracts") value
      "capturedRead" -> exactObject "captured read entry" ["entryName","kind","method","arguments","payload","result"]
        (\entry -> CapturedReadEntry <$> entry .: "entryName" <*> entry .: "method" <*> (CapturedContracts
          <$> entry .: "arguments" <*> entry .: "payload" <*> entry .: "result")) value
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
  toJSON (ExportDescription name signature origin documentation kind) = object
    ["name" .= name,"signature" .= signature,"origin" .= origin,
     "documentation" .= optionalValue documentation,"kind" .= kind]
instance FromJSON ExportDescription where
  parseJSON = exactObject "export" ["name","signature","origin","documentation","kind"] $ \fields ->
    ExportDescription <$> fields .: "name" <*> fields .: "signature" <*> fields .: "origin"
      <*> (fields .: "documentation" >>= parseOptionalValue) <*> fields .: "kind"

instance ToJSON ModuleDescription where
  toJSON (ModuleDescription name source documentation instances exports) = object
    ["name" .= name,"source" .= source,"documentation" .= optionalValue documentation,
     "instances" .= instances,"exports" .= exports]
instance FromJSON ModuleDescription where
  parseJSON = exactObject "module" ["name","source","documentation","instances","exports"] $ \fields ->
    ModuleDescription <$> fields .: "name" <*> fields .: "source" <*> (fields .: "documentation" >>= parseOptionalValue)
      <*> fields .: "instances" <*> fields .: "exports"

instance ToJSON GuestDescription where
  toJSON (GuestDescription selectedProtocol selectedEntries selectedModules) = object
    ["protocol" .= selectedProtocol,"entries" .= selectedEntries,"modules" .= selectedModules]
instance FromJSON GuestDescription where
  parseJSON = exactObject "guest description" ["protocol","entries","modules"] $ \fields ->
    GuestDescription <$> fields .: "protocol" <*> fields .: "entries" <*> fields .: "modules"

describeContract :: Description -> SchemaMetadata -> [Text] -> DescribedContract
describeContract description annotations sources = DescribedContract description annotations
  (fingerprint (contractIdentity description annotations)) sources
