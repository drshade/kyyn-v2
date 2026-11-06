{-# LANGUAGE OverloadedStrings #-}
module Evolution where
import Kyyn.Workspace.Evolution
import qualified Kyyn.Workspace.Before as Collections
import qualified Before
import Kyyn.Types.Fact (Fact(..), FactId(..))
evolution :: RecipeEvolution Root RecipeState
evolution = recipeEdit (Rationale "Append a fact and preserve private state" []) $ do
  state <- getRecipeState
  putRecipeState state
  editFacts (within Collections.items (append (Fact (FactId "new") (Before.Item 9))))
