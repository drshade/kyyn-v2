module Kyyn.Evolution.Internal
  ( RootBinding(..), RecordedRoot(..), StepObservation(..), EvolutionOutput(..), Evolution(..), evolve, edit, evaluateEvolution ) where

import Kyyn.Types.Evolution (Rationale, EvolutionFailure)
import Text.JSON.Types (JSValue)
import Kyyn.Edit (Edit)
import Kyyn.Edit.Internal (execStateT)

data RootBinding a = RootBinding String (a -> JSValue)
data RecordedRoot = RecordedRoot String JSValue deriving (Eq, Show)
data StepObservation = StepObservation Rationale RecordedRoot RecordedRoot deriving (Eq, Show)
-- | The final root and ordered observations produced by a successful evolution.
data EvolutionOutput a = EvolutionOutput a [StepObservation] deriving (Eq, Show)
-- | A transformation between root types that records its steps or returns diagnostics.
newtype Evolution a b = Evolution (a -> Either EvolutionFailure (EvolutionOutput b))

evaluateEvolution :: Evolution a b -> a -> Either EvolutionFailure (EvolutionOutput b)
evaluateEvolution (Evolution transform) = transform

edit :: RootBinding a -> Rationale -> Edit a () -> Evolution a a
edit binding rationale action = evolve binding binding rationale (execStateT action)

evolve
  :: RootBinding a -> RootBinding b -> Rationale
  -> (a -> Either EvolutionFailure b) -> Evolution a b
evolve (RootBinding beforeId encodeBefore) (RootBinding afterId encodeAfter) rationale transform =
  Evolution $ \before -> do
    after <- transform before
    pure (EvolutionOutput after
      [StepObservation rationale (RecordedRoot beforeId (encodeBefore before)) (RecordedRoot afterId (encodeAfter after))])
