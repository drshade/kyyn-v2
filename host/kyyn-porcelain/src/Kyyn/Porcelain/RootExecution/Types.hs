module Kyyn.Porcelain.RootExecution.Types (PreparedRoot(..), PreparedQuery(..), PreparedOutput(..)) where

import Kyyn.Domain.CompiledEntry (CompiledEntry)
import Kyyn.Domain.Query (QueryDescriptor)
import Kyyn.Domain.Root (Root)
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedPlugin, ConfiguredConnector)
import Kyyn.Domain.Output (OutputDefinition)

data PreparedRoot = PreparedRoot Root String CompiledEntry [PreparedQuery] [PreparedPlugin] [PreparedOutput]
  deriving (Eq, Show)

data PreparedQuery = PreparedQuery QueryDescriptor String CompiledEntry
  deriving (Eq, Show)

data PreparedOutput = PreparedOutput OutputDefinition QueryDescriptor ConfiguredConnector deriving (Eq, Show)
