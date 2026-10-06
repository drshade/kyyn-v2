{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.Evolution (Rationale(..), EvolutionFailure(..)) where

import Data.Text (Text)

import Kyyn.Types.Diagnostic (Diagnostic)
import Kyyn.Types.Evidence (EvidenceRef)

-- | Explain why an evolution step is needed and cite the evidence supporting it.
data Rationale = Rationale
  { explanation :: Text
  , evidence :: [EvidenceRef]
  } deriving (Eq, Show)

-- | Diagnostics explaining why an evolution could not produce its output.
newtype EvolutionFailure = EvolutionFailure [Diagnostic] deriving (Eq, Show)
