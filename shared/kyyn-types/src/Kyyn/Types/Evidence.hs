module Kyyn.Types.Evidence
  ( EvidenceRef(..), EvidenceId(..), EvidenceFingerprint(..), Evidence(..), EvidenceChange(..) ) where

-- | A plugin-defined item identity within one connector instance.
newtype EvidenceId = EvidenceId String deriving (Eq, Show)

-- | An opaque connector-defined token identifying captured contents.
newtype EvidenceFingerprint = EvidenceFingerprint String deriving (Eq, Show)

-- | Content fingerprint, source links and the plugin's typed captured payload.
data Evidence a = Evidence EvidenceFingerprint [String] a deriving (Eq, Show)

-- | Changes declared by a source connector against its prior snapshot.
data EvidenceChange a = NewEvidence EvidenceId (Evidence a)
  | UpdatedEvidence EvidenceId (Evidence a) | RemovedEvidence EvidenceId deriving (Eq, Show)

-- | Identify evidence supporting a rationale, including its producer, connector, source and item references.
data EvidenceRef = EvidenceRef
  { producer :: String
  , connector :: String
  , source :: String
  , references :: [String]
  } deriving (Eq, Show)
