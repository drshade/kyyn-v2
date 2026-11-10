{-# LANGUAGE OverloadedStrings #-}
module Evolution where
import Kyyn.Workspace.Evolution
import Kyyn.Types.Fact (Fact(..))
import qualified Kyyn.Workspace.Target as Collections
import qualified Kyyn.Workspace.Target.Fields as Fields
import qualified Kyyn.Workspace.Target.RecipeFlows.Flows as Recipes
import qualified Input.Previous as Input
import qualified Schema
import qualified Flows

evolution :: Evolution Schema.Root
evolution = prepare (do
  migrateCollection reason "items" Collections.items
    (traverse (\(Fact ident (Input.Item amount)) -> Right (Fact ident (Schema.Item amount "migrated"))))
  putField reason Fields.total 1
  migrateRecipe reason (RecipeId "weekly") Recipes.review
    (\(Input.State count) -> Right (Flows.State count True))
  retireRecipe reason (RecipeId "obsolete")) mempty
  where reason = Rationale "Target-only migration" []
