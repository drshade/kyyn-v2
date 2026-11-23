module Kyyn.Interactive
  ( awaitReply, ReceivedReply(..), ReplyOrigin(..), EventRef, EventBinding, event, withEvents, FlowStatus(..), ExecutionStatus(..), FlowOutcome(..), CancelScope(..), FlowHandle, startFlow, inspectFlow, awaitFlow, cancelFlow, flowRef, flowRefTyped, FlowDefinition, FlowRef, ChildFlow, interactiveRecipe, createInteractiveRecipe, child, withChildren ) where

import Kyyn.Types.EventWait (ReceivedReply(..), ReplyOrigin(..))
import Kyyn.Interactive.Event (EventRef, EventBinding(..), event, awaitReply)
import Kyyn.Interactive.Control (FlowHandle, startFlow, inspectFlow, awaitFlow, cancelFlow, flowRef, flowRefTyped)
import Kyyn.Types.FlowStatus (FlowStatus(..), ExecutionStatus(..), FlowOutcome(..), CancelScope(..))
import Kyyn.Interactive.Internal (FlowDefinition(..), FlowRef, ChildFlow(..))
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

-- | Declare a child by recipe identity and its generated source definition.
-- Evolution checking verifies the ID is interactive and still names that source.
child :: RecipeId -> FlowDefinition input output -> ChildFlow
child ident (FlowDefinition entry _ _ _ _) = ChildFlow (ChildReference ident entry)

-- | Replace the declared children this flow may start; preserve its event declarations. References are resolved against
-- the complete evolution target, so parent and child may be added together.
withChildren :: [ChildFlow] -> FlowDefinition input output -> FlowDefinition input output
withChildren refs (FlowDefinition entry bindings state input output) =
  FlowDefinition entry (bindings { children = [r | ChildFlow r <- refs] }) state input output

-- | Replace the declared event providers this flow may await; preserve its children.
withEvents :: [EventBinding] -> FlowDefinition input output -> FlowDefinition input output
withEvents refs (FlowDefinition entry bindings state input output) =
  FlowDefinition entry (bindings { events = [r | EventBinding r <- refs] }) state input output
