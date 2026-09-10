module Kyyn.Evolution
  ( Evolution, EvolutionOutput, Rationale(..), EvolutionFailure(..)
  , EvidenceRef(..), (>=>), identityEvolution, evaluateEvolution
  , module Kyyn.Edit
  ) where

import Kyyn.Types.Evolution (Rationale(..), EvolutionFailure(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Evolution.Internal
import Kyyn.Edit

infixr 1 >=>

-- | Compose two evolutions, preserving the order of their recorded steps.
(>=>) :: Evolution a b -> Evolution b c -> Evolution a c
Evolution first >=> Evolution second = Evolution $ \before -> do
  EvolutionOutput middle earlier <- first before
  EvolutionOutput after later <- second middle
  pure (EvolutionOutput after (earlier ++ later))

-- | Leave the root unchanged without recording a step.
identityEvolution :: Evolution a a
identityEvolution = Evolution (\value -> Right (EvolutionOutput value []))

evaluateEvolution :: Evolution a b -> a -> Either EvolutionFailure (EvolutionOutput b)
evaluateEvolution (Evolution transform) = transform
