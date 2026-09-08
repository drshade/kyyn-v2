module Kyyn.Types.Evidence (EvidenceRef(..)) where

data EvidenceRef = EvidenceRef
  { producer :: String
  , connector :: String
  , source :: String
  , references :: [String]
  } deriving (Eq, Show)
