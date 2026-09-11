{-# LANGUAGE GADTs #-}
module Kyyn.Types.Plugin
  ( EvidenceSnapshot(..), FetchError(..), EvidenceRead(..), FileRead(..) ) where

import Kyyn.Types.Evidence (EvidenceId, Evidence)

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
