-- | Private representation shared by recipe editing and its runtime adapter.
module Kyyn.Recipe.Evolution (RecipeEvolution(..)) where
import Kyyn.Edit (Edit)
import Kyyn.Types.Evolution (Rationale)
newtype RecipeEvolution root state = RecipeEvolution [(Rationale, Edit (root,state) ())]
instance Semigroup (RecipeEvolution root state) where
  RecipeEvolution left <> RecipeEvolution right = RecipeEvolution (left ++ right)
instance Monoid (RecipeEvolution root state) where
  mempty = RecipeEvolution []
