{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.Evidence
  ( EvidenceRef(..), EvidenceId(..), EvidenceFingerprint(..), Evidence(..), EvidenceChange(..) ) where

import Data.Text (Text)

-- | A plugin-defined item identity within one connector instance.
newtype EvidenceId = EvidenceId Text deriving (Eq, Show)

-- | An opaque connector-defined token identifying captured contents.
newtype EvidenceFingerprint = EvidenceFingerprint Text deriving (Eq, Show)

-- | Content fingerprint, source links and the plugin's typed captured payload.
data Evidence a = Evidence EvidenceFingerprint [Text] a deriving (Eq, Show)

-- | Changes declared by a source connector against its prior snapshot.
data EvidenceChange a = NewEvidence EvidenceId (Evidence a)
  | UpdatedEvidence EvidenceId (Evidence a) | RemovedEvidence EvidenceId deriving (Eq, Show)

-- | Declare supporting evidence by producer, connector instance, source and item references.
data EvidenceRef = EvidenceRef
  { producer :: Text
  , instanceName :: Text
  , source :: Text
  , references :: [Text]
  } deriving (Eq, Show)
