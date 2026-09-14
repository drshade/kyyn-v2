module Kyyn.Porcelain.RootExecution.Types (PreparedRoot(..), PreparedQuery(..)) where

import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Query (QueryDescriptor)
import Kyyn.Domain.Root (Root)
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedPlugin)

data PreparedRoot = PreparedRoot Root String CompiledProgram [PreparedQuery] [PreparedPlugin]
  deriving (Eq, Show)

data PreparedQuery = PreparedQuery QueryDescriptor String CompiledProgram
  deriving (Eq, Show)
