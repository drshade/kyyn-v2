module Kyyn.Types.Evolution (Rationale(..), EvolutionFailure(..)) where

import Kyyn.Types.Diagnostic (Diagnostic)
import Kyyn.Types.Evidence (EvidenceRef)

data Rationale = Rationale
  { explanation :: String
  , evidence :: [EvidenceRef]
  } deriving (Eq, Show)

newtype EvolutionFailure = EvolutionFailure [Diagnostic] deriving (Eq, Show)
