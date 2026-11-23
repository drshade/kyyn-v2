module Kyyn.Interactive.Internal (FlowDefinition(..), FlowRef(..), ChildFlow(..)) where

import Kyyn.Types.KnowledgeBase (RecipeId, ChildReference, FlowEntryRef, InteractionBindings)
import Kyyn.Contract (Codec, CompiledContract, ProjectionError)
import Kyyn.Recipe.Internal (RecipeType)

-- Constructed by generated bindings from the actual compiled request/result types.
data FlowDefinition input output = FlowDefinition FlowEntryRef InteractionBindings (RecipeType ()) (Codec input) (Codec output)

-- Runtime references are checked against captured declarations before start.
data FlowRef input output = FlowRef RecipeId (Either ProjectionError (CompiledContract input, CompiledContract output))
newtype ChildFlow = ChildFlow ChildReference
