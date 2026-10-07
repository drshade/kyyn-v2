module Kyyn.Recipe.Edit
  ( RecipeEvolution, RecipeEdit
  , editFacts, getRecipeState, putRecipeState, modifyRecipeState
  ) where

import Kyyn.Edit (Edit, zoom, get, put, modify)
import Kyyn.Optics (lens)
import Kyyn.Evolution.Internal (Evolution)

-- | A same-schema evolution of domain facts and one recipe's state.
type RecipeEvolution root state = Evolution (root, state) (root, state)

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
