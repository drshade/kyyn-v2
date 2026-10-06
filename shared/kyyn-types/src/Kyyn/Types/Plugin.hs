{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs, NoFieldSelectors #-}
module Kyyn.Types.Plugin
  ( SourceConnector(..), CapturedMethod(..), ConnectorInstance(..), EvidenceSnapshot(..), FetchError(..), EvidenceRead(..), FileRead(..), CapturedText(..) ) where

import Data.Text (Text)

import Kyyn.Types.Evidence (EvidenceId, Evidence, EvidenceFingerprint)

-- | A configured instance of one connector type.
newtype ConnectorInstance connector = ConnectorInstance Text

-- | Register a source connector in the plugin entry module's connectors value.
data SourceConnector = SourceConnector
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

-- | Decoded text and a fingerprint covering its source path and captured bytes.
data CapturedText = CapturedText Text EvidenceFingerprint deriving (Eq, Show)

data FileRead a where
  ListFiles :: FilePath -> Bool -> FileRead (Either FetchError [FilePath])
  ReadTextFile :: FilePath -> FileRead (Either FetchError CapturedText)
