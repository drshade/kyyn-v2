{-# LANGUAGE GADTs #-}
module Kyyn.Types.Plugin
  ( SourceConnector(..), EvidenceSnapshot(..), FetchError(..), EvidenceRead(..), FileRead(..) ) where

import Kyyn.Types.Evidence (EvidenceId, Evidence)

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
  } deriving (Eq, Show)

-- | A selected captured-evidence snapshot, read through the generated plugin bindings.
newtype EvidenceSnapshot payload = EvidenceSnapshot String

-- | A source operation could not supply its requested input.
newtype FetchError = FetchError String deriving (Eq, Show)

data EvidenceRead payload a where
  ListEvidenceIds :: EvidenceSnapshot payload -> EvidenceRead payload (Either FetchError [EvidenceId])
  ReadEvidence :: EvidenceSnapshot payload -> EvidenceId
    -> EvidenceRead payload (Either FetchError (Maybe (Evidence payload)))

data FileRead a where
  ListFiles :: FilePath -> Bool -> FileRead (Either FetchError [FilePath])
  ReadTextFile :: FilePath -> FileRead (Either FetchError String)
