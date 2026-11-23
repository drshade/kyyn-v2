module Kyyn.Interactive (FlowDefinition, interactiveRecipe) where

import Kyyn.Interactive.Internal (FlowDefinition(..))
import Kyyn.Evolution (RecipeDefinition)

-- | Register a generated interactive flow reference in the ordinary recipe
-- collection. Its shared recipe state is unit; instance progress is separate.
interactiveRecipe :: FlowDefinition input output -> RecipeDefinition ()
interactiveRecipe (FlowDefinition definition _ _) = definition
