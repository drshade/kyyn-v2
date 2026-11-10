module Kyyn.Domain.EvolutionReport (EvolutionReport(..), PluginChange(..)) where
import Kyyn.Domain.SnapshotReport (SnapshotStep)
import Kyyn.Domain.Plugin (PluginName, PluginOrigin)
import Kyyn.Domain.Path (RelativePath)
data EvolutionReport = EvolutionReport [PluginChange] [SnapshotStep] deriving (Eq, Show)
data PluginChange = PluginChange PluginName (Maybe PluginOrigin) (Maybe PluginOrigin) [RelativePath]
  deriving (Eq, Show)
