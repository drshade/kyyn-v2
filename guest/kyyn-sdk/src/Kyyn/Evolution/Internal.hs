module Kyyn.Evolution.Internal
  ( RootBinding(..), RecordedRoot(..), StepObservation(..), EvolutionOutput(..), Evolution(..), evolve ) where

import Kyyn.Types.Evolution (Rationale, EvolutionFailure)
import Text.JSON.Types (JSValue)

data RootBinding a = RootBinding String (a -> JSValue)
data RecordedRoot = RecordedRoot String JSValue deriving (Eq, Show)
data StepObservation = StepObservation Rationale RecordedRoot RecordedRoot deriving (Eq, Show)
data EvolutionOutput a = EvolutionOutput a [StepObservation] deriving (Eq, Show)
newtype Evolution a b = Evolution (a -> Either EvolutionFailure (EvolutionOutput b))

evolve
  :: RootBinding a -> RootBinding b -> Rationale
  -> (a -> Either EvolutionFailure b) -> Evolution a b
evolve (RootBinding beforeId encodeBefore) (RootBinding afterId encodeAfter) rationale transform =
  Evolution $ \before -> do
    after <- transform before
    pure (EvolutionOutput after
      [StepObservation rationale (RecordedRoot beforeId (encodeBefore before)) (RecordedRoot afterId (encodeAfter after))])
