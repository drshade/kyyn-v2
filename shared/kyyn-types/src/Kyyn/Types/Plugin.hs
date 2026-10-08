{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs, NoFieldSelectors #-}
module Kyyn.Types.Plugin
  ( Connector(..), CapturedMethod(..), ConnectorInstance(..), EvidenceSnapshot(..), FetchError(..), EvidenceRead(..), FileRead(..), CapturedText(..), FetchContext(..), FetchResult(..) ) where

import Data.Text (Text)

import Kyyn.Types.Evidence (EvidenceId, Evidence, EvidenceFingerprint)
import Kyyn.Types.Evidence (EvidenceChange)

-- | Invocation time and the position saved with the prior successful capture.
data FetchContext position = FetchContext
  { startedAt :: Text, priorPosition :: Maybe position }
  deriving (Eq, Show)

-- | Changes and their final provider position, published together on success.
data FetchResult payload position = FetchResult
  { changes :: [EvidenceChange payload], position :: position }
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
  { name :: Text
  , validateConfig :: Text
  -- | Qualified Config -> Options -> Input -> Sink (Either SinkError Result).
  , publish :: Text
  -- | Qualified pure Options value used when invocation options are omitted.
  , defaultOptions :: Text
  } deriving (Eq, Show)

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
data CapturedText = CapturedText Text EvidenceFingerprint FilePath deriving (Eq, Show)

data FileRead a where
  ListFiles :: FilePath -> Bool -> FileRead (Either FetchError [FilePath])
  ReadTextFile :: FilePath -> FileRead (Either FetchError CapturedText)
