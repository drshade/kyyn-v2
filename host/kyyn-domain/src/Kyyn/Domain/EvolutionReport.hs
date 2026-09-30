{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Domain.EvolutionReport
  ( ObservedRoot(..), StepObservation(..), EvolutionObservation(..)
  , EvolutionReport(..), PluginChange(..), StepReport(..), Change(..), RecordedFact(..)
  ) where

import Data.Aeson (Value)
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Plugin (PluginName, PluginOrigin)
import Kyyn.Domain.Path (RelativePath)
import Kyyn.Types.Evolution (Rationale)
import Kyyn.Types.Fact (FactId)
import Kyyn.Types.Curation (Curation)
import Kyyn.Types.KnowledgeBase (KnowledgeBase, Recipe)

data ObservedRoot = ObservedRoot String (KnowledgeBase Value) deriving (Eq, Show)
data StepObservation = StepObservation Rationale ObservedRoot ObservedRoot deriving (Eq, Show)
data EvolutionObservation = EvolutionObservation (KnowledgeBase Value) [StepObservation] (Maybe Curation) deriving (Eq, Show)

data EvolutionReport = EvolutionReport [PluginChange] [StepReport] (Maybe Curation) deriving (Eq, Show)
data PluginChange = PluginChange PluginName (Maybe PluginOrigin) (Maybe PluginOrigin) [RelativePath]
  deriving (Eq, Show)
data StepReport = StepReport
  { rationale :: Rationale, changes :: [Change] } deriving (Eq, Show)
data Change = FactChange
  { collection :: String, fact :: FactId
  , before :: Maybe RecordedFact, after :: Maybe RecordedFact
  } | RecipeChange FactId (Maybe Recipe) (Maybe Recipe) deriving (Eq, Show)
data RecordedFact = RecordedFact
  { contract :: RootContract, value :: Value } deriving (Eq, Show)
