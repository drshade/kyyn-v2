{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs, NoFieldSelectors #-}
module Kyyn.Types.Plugin
  ( Connector(..), EventMethod(..), RepeatSafety(..), CapturedMethod(..), ConnectorInstance(..), EvidenceSnapshot(..), FetchError(..), EvidenceRead(..), FileRead(..), CapturedText(..), FetchContext(..), FetchResult(..) ) where

import Data.Text (Text)
import Data.Aeson (ToJSON(..), FromJSON(..), object, (.=), (.:), withObject, withText, Value(String))
import qualified Data.Aeson.KeyMap as Keys
import Kyyn.Types.Json (exactObject, optionalValue, parseOptionalValue)

import Kyyn.Types.Evidence (EvidenceId, Evidence, EvidenceFingerprint)
import Kyyn.Types.Evidence (EvidenceChange)

-- | Invocation time and the position saved with the prior successful capture.
data FetchContext position = FetchContext
  { startedAt :: Text, priorPosition :: Maybe position }
  deriving (Eq, Show)

-- | Changes, final provider position and public report, published together on success.
data FetchResult payload position report = FetchResult
  { changes :: [EvidenceChange payload], position :: position, report :: report }
  deriving (Eq, Show)

-- | A configured instance of one connector type.
newtype ConnectorInstance connector = ConnectorInstance Text

-- | Register source and sink connectors in the plugin entry module's connectors value.
data Connector = SourceConnector
  { -- | Unique connector type name: an ASCII uppercase letter followed by letters, digits or underscores.
    name :: Text
  , -- | Qualified acquisition function; its checked signature supplies the data contracts.
    fetch :: Text
  , -- | Qualified pure configuration validator, with type Config -> ValidationReport.
    validateConfig :: Text
  , -- | Typed methods for reading this connector's captured evidence.
    methods :: [CapturedMethod]
  , -- | Optional qualified Config -> PluginLogin (Either LoginError ()) function.
    login :: Maybe Text
  }
  | SinkConnector
  { -- | Unique connector type name within this plugin.
    name :: Text
  , -- | Qualified pure Config -> ValidationReport validator.
    validateConfig :: Text
  , -- | Qualified Config -> Options -> Input -> Sink (Either SinkError Result).
    publish :: Text
  , -- | Qualified pure Options value used when invocation options are omitted.
    defaultOptions :: Text
  }
  | EventConnector
  { name :: Text, validateConfig :: Text, login :: Maybe Text, events :: [EventMethod] }
  deriving (Eq, Show)

data EventMethod = EventMethod
  { eventName :: Text, eventDescription :: Text, poll :: Text
  , dispatch :: Maybe (Text, RepeatSafety), minimumPollInterval :: Integer }
  deriving (Eq, Show)
data RepeatSafety = SafeToRepeat | RequireExplicitRetry deriving (Eq, Show)

instance ToJSON RepeatSafety where
  toJSON SafeToRepeat = String "safe-to-repeat"
  toJSON RequireExplicitRetry = String "require-explicit-retry"
instance FromJSON RepeatSafety where
  parseJSON = withText "dispatch repeat safety" $ \value -> case value of
    "safe-to-repeat" -> pure SafeToRepeat
    "require-explicit-retry" -> pure RequireExplicitRetry
    _ -> fail "Unknown dispatch repeat safety"
instance ToJSON EventMethod where
  toJSON (EventMethod name description poll dispatch interval) = object
    ["name" .= name,"description" .= description,"poll" .= poll,
     "dispatch" .= optionalValue dispatch,"minimumPollInterval" .= show interval]
instance FromJSON EventMethod where
  parseJSON = exactObject "event method" ["name","description","poll","dispatch","minimumPollInterval"] $ \fields -> do
    raw <- fields .: "minimumPollInterval"
    interval <- case reads raw of
      [(n, "")] | show (n :: Integer) == raw && n > 0 -> pure n
      _ -> fail "Event poll interval must be positive"
    EventMethod <$> fields .: "name" <*> fields .: "description" <*> fields .: "poll"
        <*> (fields .: "dispatch" >>= parseOptionalValue) <*> pure interval

-- | Advertise a captured-evidence reader using qualified Haskell export names.
data CapturedMethod = CapturedMethod
  { -- | Unique lowercase Haskell identifier within this connector, such as content.
    methodName :: Text
  , -- | Description shown when an agent or human discovers the method.
    methodDescription :: Text
  , -- | Qualified function: Input -> EvidenceSnapshot Payload -> CapturedRead Payload (Either FetchError Result).
    implementation :: Text
  } deriving (Eq, Show)

-- | A selected captured-evidence snapshot, read through the generated plugin bindings.
newtype EvidenceSnapshot payload = EvidenceSnapshot Text

-- | A source operation could not supply its requested input.
newtype FetchError = FetchError Text deriving (Eq, Show)

data EvidenceRead payload a where
  ListEvidenceIds :: EvidenceSnapshot payload -> EvidenceRead payload (Either FetchError [EvidenceId])
  ReadEvidence :: EvidenceSnapshot payload -> EvidenceId
    -> EvidenceRead payload (Either FetchError (Maybe (Evidence payload)))

-- | Decoded text, fingerprint and the resolved absolute source path.
data CapturedText = CapturedText Text EvidenceFingerprint Text deriving (Eq, Show)

data FileRead a where
  ListFiles :: Text -> Bool -> FileRead (Either FetchError [Text])
  ReadTextFile :: Text -> FileRead (Either FetchError CapturedText)

-- A fixed private bootstrap evaluates these authored registrations in the
-- selected compiler environment. Its transport shares this one strict codec.
instance ToJSON Connector where
  toJSON (SourceConnector name fetch validate methods login) = object
    ["name" .= name,"fetch" .= fetch,"validateConfig" .= validate,"methods" .= methods,
     "login" .= optionalValue login]
  toJSON (SinkConnector name validate publish defaults) = object
    ["name" .= name,"validateConfig" .= validate,"publish" .= publish,"defaultOptions" .= defaults]
  toJSON (EventConnector name validate login events) = object
    ["name" .= name,"validateConfig" .= validate,"login" .= optionalValue login,"events" .= events]
instance FromJSON Connector where
  parseJSON value = withObject "connector" (\fields ->
    if Keys.member "fetch" fields then
      exactObject "source connector" ["name","fetch","validateConfig","methods","login"]
        (\selected -> SourceConnector <$> selected .: "name" <*> selected .: "fetch"
          <*> selected .: "validateConfig" <*> selected .: "methods"
          <*> (selected .: "login" >>= parseOptionalValue)) value
    else if Keys.member "events" fields then
      exactObject "event connector" ["name","validateConfig","login","events"]
        (\selected -> EventConnector <$> selected .: "name" <*> selected .: "validateConfig"
          <*> (selected .: "login" >>= parseOptionalValue) <*> selected .: "events") value
    else exactObject "sink connector" ["name","validateConfig","publish","defaultOptions"]
      (\selected -> SinkConnector <$> selected .: "name" <*> selected .: "validateConfig"
        <*> selected .: "publish" <*> selected .: "defaultOptions") value) value

instance ToJSON CapturedMethod where
  toJSON (CapturedMethod name description implementation) = object
    ["name" .= name,"description" .= description,"implementation" .= implementation]
instance FromJSON CapturedMethod where
  parseJSON = exactObject "captured method" ["name","description","implementation"] $ \fields ->
    CapturedMethod <$> fields .: "name" <*> fields .: "description" <*> fields .: "implementation"
