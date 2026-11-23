module Kyyn.Interactive
  ( FlowDefinition, FlowRef, ChildFlow, interactiveRecipe, createInteractiveRecipe, flowRef, childFlow, withChildren ) where

import Kyyn.Interactive.Internal (FlowDefinition(..), FlowRef(..), ChildFlow(..))
import Kyyn.Recipe.Internal (RecipeDefinition(..), KnowledgeBase)
import Kyyn.Evolution.KnowledgeBase (createRecipe)
import Kyyn.Edit (Edit)
import Kyyn.Types.KnowledgeBase
  (RecipeId, Recipe(..), Lifetime(..), InteractionBindings(..), ChildReference(..))

-- | Register a generated source definition in the existing recipe collection.
-- Shared state is unit; each interactive instance owns its progress.
interactiveRecipe :: FlowDefinition input output -> RecipeDefinition ()
interactiveRecipe (FlowDefinition entry bindings state _ _) =
  RecipeDefinition (ClosedAgent (Interactive bindings) entry) state

createInteractiveRecipe :: RecipeId -> FlowDefinition input output -> Edit (KnowledgeBase root) ()
createInteractiveRecipe ident definition = createRecipe ident (interactiveRecipe definition) ()

-- | Typed witness for an identified recipe. Evolution checking verifies that
-- the target declares this ID with the same interactive source definition.
flowRef :: RecipeId -> FlowDefinition input output -> FlowRef input output
flowRef ident (FlowDefinition entry _ _ input output) =
  FlowRef (ChildReference ident entry) input output

-- | Existential child declaration; use the original FlowRef at typed call sites.
childFlow :: FlowRef input output -> ChildFlow
childFlow (FlowRef reference _ _) = ChildFlow reference

-- | Declare the children this flow may start. References are resolved against
-- the complete evolution target, so parent and child may be added together.
withChildren :: [ChildFlow] -> FlowDefinition input output -> FlowDefinition input output
withChildren refs (FlowDefinition entry _ state input output) =
  FlowDefinition entry (InteractionBindings [r | ChildFlow r <- refs]) state input output
