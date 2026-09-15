module Kyyn.Domain.Tool (ToolDefinition(..), ToolDescriptor(..)) where

import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Plugin (MethodName, QualifiedTypeName)

data ToolDefinition = ToolDefinition MethodName String QualifiedTypeName QualifiedTypeName String deriving (Eq, Show)
data ToolDescriptor = ToolDescriptor MethodName String CheckedContract CheckedContract deriving (Eq, Show)
