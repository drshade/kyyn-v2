{-# LANGUAGE GADTs #-}
module Kyyn.Types.Plugin
  ( SourceConnector(..), CapturedMethod(..), ConnectorInstance(..), EvidenceSnapshot(..), FetchError(..), EvidenceRead(..), FileRead(..), CapturedText(..) ) where

import Kyyn.Types.Evidence (EvidenceId, Evidence, EvidenceFingerprint)

-- | A configured instance of one connector type.
newtype ConnectorInstance connector = ConnectorInstance String

-- | Register a source connector in the plugin entry module's connectors value.
data SourceConnector = SourceConnector
  { -- | Unique connector type name: an ASCII uppercase letter followed by letters, digits or underscores.
    name :: String
  , -- | Qualified Haskell type of this connector's configuration, for example LocalFile.Types.FolderConfig.
    configType :: String
  , -- | Qualified Haskell type of one captured evidence payload, for example LocalFile.Types.Document.
    payloadType :: String
  , -- | Qualified acquisition function. Its Config and Payload must match this declaration.
    fetch :: String
  , -- | Qualified pure configuration validator, with type Config -> ValidationReport.
    validateConfig :: String
  , -- | Typed methods for reading this connector's captured evidence.
    methods :: [CapturedMethod]
  } deriving (Eq, Show)

-- | Advertise a captured-evidence reader using qualified Haskell export names.
data CapturedMethod = CapturedMethod
  { -- | Unique lowercase Haskell identifier within this connector, such as content.
    methodName :: String
  , -- | Description shown when an agent or human discovers the method.
    methodDescription :: String
  , -- | Qualified Haskell input type or type alias.
    inputType :: String
  , -- | Qualified Haskell result type or type alias.
    resultType :: String
  , -- | Qualified function: Input -> EvidenceSnapshot Payload -> CapturedRead (Either FetchError Result).
    implementation :: String
  } deriving (Eq, Show)

-- | A selected captured-evidence snapshot, read through the generated plugin bindings.
newtype EvidenceSnapshot payload = EvidenceSnapshot String

-- | A source operation could not supply its requested input.
newtype FetchError = FetchError String deriving (Eq, Show)

data EvidenceRead payload a where
  ListEvidenceIds :: EvidenceSnapshot payload -> EvidenceRead payload (Either FetchError [EvidenceId])
  ReadEvidence :: EvidenceSnapshot payload -> EvidenceId
    -> EvidenceRead payload (Either FetchError (Maybe (Evidence payload)))

-- | Decoded text and a fingerprint covering its source path and captured bytes.
data CapturedText = CapturedText String EvidenceFingerprint deriving (Eq, Show)

data FileRead a where
  ListFiles :: FilePath -> Bool -> FileRead (Either FetchError [FilePath])
  ReadTextFile :: FilePath -> FileRead (Either FetchError CapturedText)
