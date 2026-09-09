module Kyyn.Porcelain.RootExecution.Types (PreparedRoot(..), PreparedQuery(..)) where

import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Query (QueryDescriptor)
import Kyyn.Domain.Root (Root)

data PreparedRoot = PreparedRoot Root String CompiledProgram [PreparedQuery]
  deriving (Eq, Show)

data PreparedQuery = PreparedQuery QueryDescriptor String CompiledProgram
  deriving (Eq, Show)
