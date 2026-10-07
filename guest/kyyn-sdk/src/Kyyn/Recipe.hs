{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Recipe
  ( RecipeInput(..), RecipeProposal(..), ProposedStep(..), FactEdit(..)
  , RecipeId(..), module Kyyn.Recipe.Edit
  ) where

import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Kyyn.Evolution.Proposal
import Kyyn.Recipe.Edit

-- | The accepted root, invocation arguments and the selected recipe's state.
data RecipeInput root input state = RecipeInput
  { root :: root, input :: input, state :: state }
  deriving (Eq, Show)
