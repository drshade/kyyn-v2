module Kyyn.Interactive (FlowRef, interactiveRecipe) where

import Kyyn.Interactive.Internal (FlowRef(..))
import Kyyn.Evolution (RecipeDefinition)

-- | Register a generated interactive flow reference in the ordinary recipe
-- collection. Its shared recipe state is unit; instance progress is separate.
interactiveRecipe :: FlowRef input output -> RecipeDefinition ()
interactiveRecipe (FlowRef definition _ _) = definition
