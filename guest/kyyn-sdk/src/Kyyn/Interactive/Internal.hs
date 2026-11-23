module Kyyn.Interactive.Internal (FlowDefinition(..)) where

import Kyyn.Contract (Codec)
import Kyyn.Recipe.Internal (RecipeDefinition)

-- Constructed by generated bindings from the actual compiled request/result types.
data FlowDefinition input output = FlowDefinition (RecipeDefinition ()) (Codec input) (Codec output)
