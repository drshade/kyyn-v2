module Kyyn.Interactive.Internal (FlowRef(..)) where

import Kyyn.Contract (Codec)
import Kyyn.Recipe.Internal (RecipeDefinition)

-- Constructed by generated bindings from the actual compiled request/result types.
data FlowRef input output = FlowRef (RecipeDefinition ()) (Codec input) (Codec output)
