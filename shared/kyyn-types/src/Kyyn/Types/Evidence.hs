module Kyyn.Types.Evidence (EvidenceRef(..)) where

-- | Identify evidence supporting a rationale, including its producer, connector, source and item references.
data EvidenceRef = EvidenceRef
  { producer :: String
  , connector :: String
  , source :: String
  , references :: [String]
  } deriving (Eq, Show)
