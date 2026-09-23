{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Domain.EvolutionReport
  ( ObservedRoot(..), StepObservation(..), EvolutionObservation(..)
  , EvolutionReport(..), StepReport(..), FactChange(..), RecordedFact(..)
  ) where

import Data.Aeson (Value)
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Types.Evolution (Rationale)
import Kyyn.Types.Fact (FactId)
import Kyyn.Types.Curation (Curation)

data ObservedRoot = ObservedRoot String Value deriving (Eq, Show)
data StepObservation = StepObservation Rationale ObservedRoot ObservedRoot deriving (Eq, Show)
data EvolutionObservation = EvolutionObservation Value [StepObservation] (Maybe Curation) deriving (Eq, Show)

data EvolutionReport = EvolutionReport [StepReport] (Maybe Curation) deriving (Eq, Show)
data StepReport = StepReport
  { rationale :: Rationale, changes :: [FactChange] } deriving (Eq, Show)
data FactChange = FactChange
  { collection :: String, fact :: FactId
  , before :: Maybe RecordedFact, after :: Maybe RecordedFact
  } deriving (Eq, Show)
data RecordedFact = RecordedFact
  { contract :: RootContract, value :: Value } deriving (Eq, Show)
