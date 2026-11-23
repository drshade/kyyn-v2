module Kyyn.Interactive.Internal (FlowDefinition(..), FlowRef(..), ChildFlow(..)) where

import Kyyn.Types.KnowledgeBase (ChildReference, FlowEntryRef)
import Kyyn.Contract (Codec)
import Kyyn.Recipe.Internal (RecipeType)

-- Constructed by generated bindings from the actual compiled request/result types.
data FlowDefinition input output = FlowDefinition FlowEntryRef (RecipeType ()) (Codec input) (Codec output)

-- The recipe identity is resolved against target declarations during checking.
data FlowRef input output = FlowRef ChildReference (Codec input) (Codec output)
newtype ChildFlow = ChildFlow ChildReference
