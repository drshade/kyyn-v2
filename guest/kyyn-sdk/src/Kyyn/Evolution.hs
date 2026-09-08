module Kyyn.Evolution
  ( Evolution, EvolutionOutput, RootBinding, Rationale(..), EvolutionFailure(..)
  , EvidenceRef(..), evolve, (>=>), identityEvolution, evaluateEvolution
  ) where

import Kyyn.Types.Evolution (Rationale(..), EvolutionFailure(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Evolution.Internal

infixr 1 >=>

evolve
  :: RootBinding a -> RootBinding b -> Rationale
  -> (a -> Either EvolutionFailure b) -> Evolution a b
evolve (RootBinding beforeId encodeBefore) (RootBinding afterId encodeAfter) rationale transform =
  Evolution $ \before -> do
    after <- transform before
    pure (EvolutionOutput after
      [StepObservation rationale (RecordedRoot beforeId (encodeBefore before)) (RecordedRoot afterId (encodeAfter after))])

(>=>) :: Evolution a b -> Evolution b c -> Evolution a c
Evolution first >=> Evolution second = Evolution $ \before -> do
  EvolutionOutput middle earlier <- first before
  EvolutionOutput after later <- second middle
  pure (EvolutionOutput after (earlier ++ later))

identityEvolution :: Evolution a a
identityEvolution = Evolution (\value -> Right (EvolutionOutput value []))

evaluateEvolution :: Evolution a b -> a -> Either EvolutionFailure (EvolutionOutput b)
evaluateEvolution (Evolution transform) = transform
