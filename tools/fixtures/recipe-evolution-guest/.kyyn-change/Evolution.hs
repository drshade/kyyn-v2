module Evolution where
import Kyyn.Workspace.Evolution
import qualified Kyyn.Workspace.Target as Collections
import qualified Schema
import qualified Flows
import Kyyn.Types.Fact (Fact(..), FactId(..))
evolution :: RecipeEvolution Root RecipeState
evolution = recipeEdit (Rationale "Append a fact and preserve private state" []) $ do
  putRecipeState (Flows.State 5 True)
  editFacts (within Collections.items (append (Fact (FactId "new") (Schema.Item 9 "new"))))
