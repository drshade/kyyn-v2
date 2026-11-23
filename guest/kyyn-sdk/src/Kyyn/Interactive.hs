module Kyyn.Interactive
  ( FlowDefinition, FlowRef, ChildFlow, interactiveRecipe, flowRef, childFlow, withChildren ) where

import Kyyn.Interactive.Internal (FlowDefinition(..), FlowRef(..), ChildFlow(..))
import Kyyn.Recipe.Internal (RecipeDefinition(..))
import Kyyn.Types.KnowledgeBase
  (RecipeId, Recipe(..), Lifetime(..), InteractionBindings(..), ChildReference(..))

-- | Register a generated source definition in the existing recipe collection.
-- Shared state is unit; each interactive instance owns its progress.
interactiveRecipe :: FlowDefinition input output -> RecipeDefinition ()
interactiveRecipe = withChildren []

-- | Typed witness for an identified recipe. Evolution checking verifies that
-- the target declares this ID with the same interactive source definition.
flowRef :: RecipeId -> FlowDefinition input output -> FlowRef input output
flowRef ident (FlowDefinition entry _ input output) =
  FlowRef (ChildReference ident entry) input output

-- | Existential child declaration; use the original FlowRef at typed call sites.
childFlow :: FlowRef input output -> ChildFlow
childFlow (FlowRef reference _ _) = ChildFlow reference

-- | Declare the children this flow may start. References are resolved against
-- the complete evolution target, so parent and child may be added together.
withChildren :: [ChildFlow] -> FlowDefinition input output -> RecipeDefinition ()
withChildren refs (FlowDefinition entry state _ _) =
  RecipeDefinition (ClosedAgent (Interactive (InteractionBindings [r | ChildFlow r <- refs])) entry) state
