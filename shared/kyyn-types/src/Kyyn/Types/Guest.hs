{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable, OverloadedStrings #-}
module Kyyn.Types.Guest
  ( EvolutionContracts(..), RecipeInvocation(..), DescriptionFormat(..), RecipeContracts(..), QueryInvocation(..), Invocation(..), ConnectorEntries(..), CapturedEntry(..), entryNames, SinkDefaultsInvocation(..)
  , LoginInvocation(..), SinkInvocation(..), SinkContracts(..)
  , AcquisitionInvocation(..), AcquisitionContext(..), ConnectorIdentity(..), AcquisitionContracts(..)
  , GuestRequest(..), CapturedInvocation(..), GuestDescription(..), DescribedContract(..), EntryDescription, GuestEntry(..)
  , QueryContracts(..), ToolContracts(..), CapturedContracts(..), CapturedMethodIdentity(..), ModuleDescription(..), ExportDescription(..), ExportKind(..)
  , protocolIdentity, describeContract
  ) where

import Data.Aeson (ToJSON(..), FromJSON(..), Value(..), object, (.=), (.:), withObject, withText)
import Data.Text (Text)
import Kyyn.Types.Contract
import Kyyn.Types.Json (exactObject, optionalValue, parseOptionalValue)
import Kyyn.Types.SchemaMetadata

-- One request codec is used by the host and the executable it describes.
data GuestRequest = Describe | Invoke Text Value deriving (Eq, Show)
data DescriptionFormat = Tree | Dot | Mermaid deriving (Eq, Show)
data RecipeInvocation = RunRecipe Value Value Value | RenderRecipe DescriptionFormat deriving (Eq, Show)
instance ToJSON DescriptionFormat where
  toJSON format = String (case format of Tree -> "tree"; Dot -> "dot"; Mermaid -> "mermaid")
instance FromJSON DescriptionFormat where
  parseJSON = withText "recipe description format" $ \format -> case format of
    "tree" -> pure Tree
    "dot" -> pure Dot
    "mermaid" -> pure Mermaid
    _ -> fail "Unknown recipe description format"
instance ToJSON RecipeInvocation where
  toJSON (RunRecipe root input state) = object ["operation" .= String "run","root" .= root,"input" .= input,"state" .= state]
  toJSON (RenderRecipe format) = object ["operation" .= String "render","format" .= format]
instance FromJSON RecipeInvocation where
  parseJSON value = withObject "recipe invocation" (\fields -> do
    operation <- fields .: "operation"
    case operation :: Text of
      "run" -> exactObject "recipe run" ["operation","root","input","state"]
        (\request -> RunRecipe <$> request .: "root" <*> request .: "input" <*> request .: "state") value
      "render" -> exactObject "recipe render" ["operation","format"]
        (\request -> RenderRecipe <$> request .: "format") value
      _ -> fail "Unknown recipe operation") value

data QueryInvocation = QueryInvocation Value Value deriving (Eq, Show)
instance ToJSON QueryInvocation where
  toJSON (QueryInvocation root arguments) = object ["root" .= root,"arguments" .= arguments]
instance FromJSON QueryInvocation where
  parseJSON = exactObject "query invocation" ["root","arguments"] $ \fields ->
    QueryInvocation <$> fields .: "root" <*> fields .: "arguments"

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

newtype LoginInvocation = LoginInvocation Value deriving (Eq, Show)
data SinkInvocation = SinkInvocation Value Value Value deriving (Eq, Show)

instance ToJSON LoginInvocation where
  toJSON (LoginInvocation config) = object ["config" .= config]
instance FromJSON LoginInvocation where
  parseJSON = exactObject "login invocation" ["config"] $ \fields -> LoginInvocation <$> fields .: "config"
instance ToJSON SinkInvocation where
  toJSON (SinkInvocation config options input) = object ["config" .= config,"options" .= options,"input" .= input]
instance FromJSON SinkInvocation where
  parseJSON = exactObject "sink invocation" ["config","options","input"] $ \fields ->
    SinkInvocation <$> fields .: "config" <*> fields .: "options" <*> fields .: "input"

data SinkContracts contract = SinkContracts contract contract contract contract
  deriving (Eq, Show, Functor, Foldable, Traversable)
instance ToJSON contract => ToJSON (SinkContracts contract) where
  toJSON (SinkContracts config options input result) = object
    ["config" .= config,"options" .= options,"input" .= input,"result" .= result]
instance FromJSON contract => FromJSON (SinkContracts contract) where
  parseJSON = exactObject "sink contracts" ["config","options","input","result"] $ \fields ->
    SinkContracts <$> fields .: "config" <*> fields .: "options" <*> fields .: "input" <*> fields .: "result"

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
  | EvolutionEntry { entryName :: Text, evolutionContracts :: EvolutionContracts contract }
  | RecipeEntry { entryName :: Text, recipeName :: Text, recipeContracts :: RecipeContracts contract }
  | ToolEntry { entryName :: Text, toolName :: Text, toolDescription :: Text, toolContracts :: ToolContracts contract }
  | QueryEntry { entryName :: Text, queryContracts :: QueryContracts contract }
  | ConnectorEntry { connectorIdentity :: ConnectorIdentity, connectorEntries :: ConnectorEntries contract }
  | ContractEntry { entryName :: Text, describedContract :: contract }
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- A connector is complete by construction. Named invocations carry their own
-- contracts; no host workflow joins independent roles by connector strings.
data Invocation contract = Invocation { invocationName :: Text, invocationContract :: contract }
  deriving (Eq, Show, Functor, Foldable, Traversable)
data CapturedEntry contract = CapturedEntry
  { capturedName :: Text, capturedDescription :: Text, capturedInvocation :: Invocation (CapturedContracts contract) }
  deriving (Eq, Show, Functor, Foldable, Traversable)
data ConnectorEntries contract
  = SourceEntries
      { configure :: Invocation contract
      , acquire :: Invocation (AcquisitionContracts contract)
      , login :: Maybe (Invocation contract)
      , methods :: [CapturedEntry contract]
      }
  | SinkEntries
      { configure :: Invocation contract
      , publish :: Invocation (SinkContracts contract)
      , defaults :: Invocation contract
      }
  deriving (Eq, Show, Functor, Foldable, Traversable)

entryNames :: GuestEntry contract -> [Text]
entryNames (ConnectorEntry _ (SourceEntries config acquisition authentication captured)) =
  [invocationName config,invocationName acquisition] ++ maybe [] (pure . invocationName) authentication ++
  map (invocationName . capturedInvocation) captured
entryNames (ConnectorEntry _ (SinkEntries config publication options)) =
  [invocationName config,invocationName publication,invocationName options]
entryNames entry = [entryName entry]

instance ToJSON contract => ToJSON (Invocation contract) where
  toJSON (Invocation name contract) = object ["entryName" .= name,"contract" .= contract]
instance FromJSON contract => FromJSON (Invocation contract) where
  parseJSON = exactObject "invocation" ["entryName","contract"] $ \fields ->
    Invocation <$> fields .: "entryName" <*> fields .: "contract"
instance ToJSON contract => ToJSON (CapturedEntry contract) where
  toJSON (CapturedEntry name description invocation) = object
    ["name" .= name,"description" .= description,"invocation" .= invocation]
instance FromJSON contract => FromJSON (CapturedEntry contract) where
  parseJSON = exactObject "captured method" ["name","description","invocation"] $ \fields ->
    CapturedEntry <$> fields .: "name" <*> fields .: "description" <*> fields .: "invocation"
instance ToJSON contract => ToJSON (ConnectorEntries contract) where
  toJSON (SourceEntries config acquisition authentication captured) = object
    ["kind" .= String "source","configure" .= config,"acquire" .= acquisition,
     "login" .= optionalValue authentication,"methods" .= captured]
  toJSON (SinkEntries config publication options) = object
    ["kind" .= String "sink","configure" .= config,"publish" .= publication,"defaults" .= options]
instance FromJSON contract => FromJSON (ConnectorEntries contract) where
  parseJSON value = withObject "connector entries" (\fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "source" -> exactObject "source connector" ["kind","configure","acquire","login","methods"]
        (\entry -> SourceEntries <$> entry .: "configure" <*> entry .: "acquire"
          <*> (entry .: "login" >>= parseOptionalValue) <*> entry .: "methods") value
      "sink" -> exactObject "sink connector" ["kind","configure","publish","defaults"]
        (\entry -> SinkEntries <$> entry .: "configure" <*> entry .: "publish" <*> entry .: "defaults") value
      _ -> fail "Unknown connector kind") value

-- Defaults take an explicit empty request, shared by both sides of the boundary.
data SinkDefaultsInvocation = SinkDefaultsInvocation deriving (Eq, Show)
instance ToJSON SinkDefaultsInvocation where
  toJSON SinkDefaultsInvocation = object []
instance FromJSON SinkDefaultsInvocation where
  parseJSON = exactObject "sink defaults invocation" [] (const (pure SinkDefaultsInvocation))

data QueryContracts contract = QueryContracts
  { rootContract :: contract, argumentContract :: contract, resultContract :: contract }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data EvolutionContracts contract = AdHocContracts contract contract | RecipeEvolutionContracts contract contract
  deriving (Eq, Show, Functor, Foldable, Traversable)
instance ToJSON contract => ToJSON (EvolutionContracts contract) where
  toJSON (AdHocContracts before after) = object ["kind" .= String "ad-hoc","before" .= before,"after" .= after]
  toJSON (RecipeEvolutionContracts root state) = object ["kind" .= String "recipe","root" .= root,"state" .= state]
instance FromJSON contract => FromJSON (EvolutionContracts contract) where
  parseJSON value = withObject "evolution contracts" (\fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "ad-hoc" -> exactObject "ad-hoc evolution contracts" ["kind","before","after"]
        (\entry -> AdHocContracts <$> entry .: "before" <*> entry .: "after") value
      "recipe" -> exactObject "recipe evolution contracts" ["kind","root","state"]
        (\entry -> RecipeEvolutionContracts <$> entry .: "root" <*> entry .: "state") value
      _ -> fail "Unknown evolution kind") value

data RecipeContracts contract = RecipeContracts contract contract contract
  deriving (Eq, Show, Functor, Foldable, Traversable)
instance ToJSON contract => ToJSON (RecipeContracts contract) where
  toJSON (RecipeContracts root input state) = object ["root" .= root,"input" .= input,"state" .= state]
instance FromJSON contract => FromJSON (RecipeContracts contract) where
  parseJSON = exactObject "recipe contracts" ["root","input","state"] $ \fields ->
    RecipeContracts <$> fields .: "root" <*> fields .: "input" <*> fields .: "state"

data ToolContracts contract = ToolContracts contract contract
  deriving (Eq, Show, Functor, Foldable, Traversable)

data CapturedMethodIdentity = CapturedMethodIdentity
  { pluginName :: Text, connectorName :: Text, methodName :: Text, methodDescription :: Text }
  deriving (Eq, Show)

data CapturedContracts contract = CapturedContracts
  { inputContract :: contract, payloadContract :: contract, outputContract :: contract }
  deriving (Eq, Show, Functor, Foldable, Traversable)

instance ToJSON contract => ToJSON (CapturedContracts contract) where
  toJSON (CapturedContracts input payload output) = object
    ["input" .= input,"payload" .= payload,"output" .= output]
instance FromJSON contract => FromJSON (CapturedContracts contract) where
  parseJSON = exactObject "captured contracts" ["input","payload","output"] $ \fields ->
    CapturedContracts <$> fields .: "input" <*> fields .: "payload" <*> fields .: "output"

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
  toJSON (EvolutionEntry name contracts) = object ["kind" .= String "evolution","entryName" .= name,"contracts" .= contracts]
  toJSON (RecipeEntry entry name contracts) = object
    ["entryName" .= entry,"kind" .= String "recipe","name" .= name,"contracts" .= contracts]
  toJSON (ToolEntry entry name description (ToolContracts input result)) = object
    ["entryName" .= entry,"kind" .= String "tool","name" .= name,"description" .= description,
     "input" .= input,"result" .= result]
  toJSON (QueryEntry name (QueryContracts root arguments result)) = object
    ["entryName" .= name,"kind" .= String "query","root" .= root,"arguments" .= arguments,"result" .= result]
  toJSON (ConnectorEntry ident selected) = object
    ["kind" .= String "connector","identity" .= ident,"entries" .= selected]
  toJSON (ContractEntry name value) = object ["entryName" .= name,"kind" .= String "contract","value" .= value]
instance FromJSON contract => FromJSON (GuestEntry contract) where
  parseJSON value = withObject "guest entry" (\fields -> do
    kind <- fields .: "kind"
    case kind :: Text of
      "validator" -> exactObject "validator entry" ["entryName","kind","root"]
        (\entry -> ValidatorEntry <$> entry .: "entryName" <*> entry .: "root") value
      "evolution" -> exactObject "evolution entry" ["entryName","kind","contracts"]
        (\entry -> EvolutionEntry <$> entry .: "entryName" <*> entry .: "contracts") value
      "recipe" -> exactObject "recipe entry" ["entryName","kind","name","contracts"]
        (\entry -> RecipeEntry <$> entry .: "entryName" <*> entry .: "name" <*> entry .: "contracts") value
      "tool" -> exactObject "tool entry" ["entryName","kind","name","description","input","result"]
        (\entry -> ToolEntry <$> entry .: "entryName" <*> entry .: "name" <*> entry .: "description"
          <*> (ToolContracts <$> entry .: "input" <*> entry .: "result")) value
      "query" -> exactObject "query entry" ["entryName","kind","root","arguments","result"]
        (\entry -> QueryEntry <$> entry .: "entryName" <*> (QueryContracts
          <$> entry .: "root" <*> entry .: "arguments" <*> entry .: "result")) value
      "connector" -> exactObject "connector entry" ["kind","identity","entries"]
        (\entry -> ConnectorEntry <$> entry .: "identity" <*> entry .: "entries") value
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
