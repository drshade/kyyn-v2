{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.Evidence
  ( EvidenceRef(..), EvidenceId(..), EvidenceFingerprint(..), EvidencePayload(..), Evidence(..), EvidenceChange(..) ) where

import Data.Text (Text)

-- | A plugin-defined item identity within one connector instance.
newtype EvidenceId = EvidenceId Text deriving (Eq, Show)

-- | An opaque connector-defined token identifying captured contents.
newtype EvidenceFingerprint = EvidenceFingerprint Text deriving (Eq, Show)

-- | Retained content or a known item whose content has been discarded locally.
data EvidencePayload a = Available a | Truncated deriving (Eq, Show)

-- | Content fingerprint, external source references and payload availability.
data Evidence a = Evidence EvidenceFingerprint [Text] (EvidencePayload a) deriving (Eq, Show)

-- | Changes declared by a source connector against its prior snapshot.
data EvidenceChange a = NewEvidence EvidenceId (Evidence a)
  | UpdatedEvidence EvidenceId (Evidence a) | RemovedEvidence EvidenceId
  | SetEvidencePayload EvidenceId EvidenceFingerprint (EvidencePayload a) deriving (Eq, Show)

-- | Declare supporting evidence by producer, connector instance, source and item references.
data EvidenceRef = EvidenceRef
  { producer :: Text
  , instanceName :: Text
  , source :: Text
  , externalReferences :: [Text]
  } deriving (Eq, Show)
