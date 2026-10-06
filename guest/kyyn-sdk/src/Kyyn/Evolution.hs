{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Evolution
  ( Evolution, Rationale(..), EvolutionFailure(..)
  , EvidenceRef(..), EvidenceId(..), (>=>), identityEvolution, withCuration
  , RecipeId(..), EvidenceScope(..), Acknowledgement(..), Curation(..)
  , KnowledgeBase(..), Recipe(..), FlowEntryRef(..), facts, recipes, onFacts
  , module Kyyn.Edit
  ) where

import Kyyn.Types.Evolution (Rationale(..), EvolutionFailure(..))
import Kyyn.Types.Evidence (EvidenceRef(..), EvidenceId(..))
import Kyyn.Types.Curation
import Kyyn.Types.Diagnostic (errorDiagnostic)
import Kyyn.Evolution.Internal
import Kyyn.Evolution.KnowledgeBase
import Kyyn.Edit

infixr 1 >=>

-- | Compose two evolutions, preserving the order of their recorded steps.
(>=>) :: Evolution a b -> Evolution b c -> Evolution a c
Evolution first >=> Evolution second = Evolution $ \before -> do
  EvolutionOutput middle earlier firstCuration <- first before
  EvolutionOutput after later secondCuration <- second middle
  curation <- combineCuration firstCuration secondCuration
  pure (EvolutionOutput after (earlier ++ later) curation)

-- | Leave the root unchanged without recording a step.
identityEvolution :: Evolution a a
identityEvolution = Evolution (\value -> Right (EvolutionOutput value [] Nothing))

-- | Append declarations of handled evidence to an evolution's result.
-- Composed declarations must name the same recipe.
withCuration :: Curation -> Evolution a b -> Evolution a b
withCuration declaration (Evolution transform) = Evolution $ \before -> do
  EvolutionOutput after steps previous <- transform before
  combined <- combineCuration previous (Just declaration)
  pure (EvolutionOutput after steps combined)

combineCuration :: Maybe Curation -> Maybe Curation -> Either EvolutionFailure (Maybe Curation)
combineCuration Nothing later = Right later
combineCuration earlier Nothing = Right earlier
combineCuration (Just (Curation first earlier)) (Just (Curation second later))
  | first == second = Right (Just (Curation first (earlier ++ later)))
  | otherwise = Left (EvolutionFailure [errorDiagnostic "curation.recipe-conflict"
      "One evolution can handle evidence for only one recipe"])
