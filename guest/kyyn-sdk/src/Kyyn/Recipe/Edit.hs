module Kyyn.Recipe.Edit
  ( RecipeEvolution, RecipeEdit, recipeEdit
  , editFacts, getRecipeState, putRecipeState, modifyRecipeState
  ) where

import Kyyn.Edit (Edit, zoom, get, put, modify)
import Kyyn.Optics (lens)
import Kyyn.Recipe.Evolution (RecipeEvolution(..))
import Kyyn.Types.Evolution (Rationale)

-- | Record one same-schema edit of domain facts and selected recipe state.
recipeEdit :: Rationale -> RecipeEdit root state () -> RecipeEvolution root state
recipeEdit reason action = RecipeEvolution [(reason,action)]

-- | A fallible edit of domain facts and the selected recipe's state.
type RecipeEdit root state = Edit (root, state)

-- | Edit domain facts while preserving the recipe state.
editFacts :: Edit root a -> RecipeEdit root state a
editFacts = zoom (lens fst (\(_, state) root -> (root, state)))

-- | Read the selected recipe's current state.
getRecipeState :: RecipeEdit root state state
getRecipeState = zoom recipeState get

-- | Replace the selected recipe's state while preserving domain facts.
putRecipeState :: state -> RecipeEdit root state ()
putRecipeState state = zoom recipeState (put state)

-- | Transform the selected recipe's state while preserving domain facts.
modifyRecipeState :: (state -> state) -> RecipeEdit root state ()
modifyRecipeState transform = zoom recipeState (modify transform)

recipeState :: Functor f => (state -> f state) -> (root, state) -> f (root, state)
recipeState = lens snd (\(root, _) state -> (root, state))
