{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.PluginPreparation
  ( PluginPreparation(..), PreparedPlugin(..), PreparedConnector(..), ConfiguredConnector(..)
  , preparePlugins, validatePlugins ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Plugin (PluginName, PackageIdentity, ConnectorTypeName, ConnectorName, BindingName)
import Kyyn.Domain.Value (CheckedValue)

data PreparedConnector = PreparedConnector ConnectorTypeName CheckedContract CheckedContract CompiledProgram CompiledProgram
  deriving (Eq, Show)
data ConfiguredConnector = ConfiguredConnector ConnectorName BindingName PreparedConnector CheckedValue deriving (Eq, Show)
data PreparedPlugin = PreparedPlugin PluginName PackageIdentity [PreparedConnector] [ConfiguredConnector] deriving (Eq, Show)

data PluginPreparation :: Effect where
  PreparePlugins :: FileTree -> PluginPreparation m (Either [Diagnostic] [PreparedPlugin])
  ValidatePlugins :: [PreparedPlugin] -> PluginPreparation m (Either [Diagnostic] ValidationReport)
type instance DispatchOf PluginPreparation = Dynamic

preparePlugins :: PluginPreparation :> es => FileTree -> Eff es (Either [Diagnostic] [PreparedPlugin])
preparePlugins = send . PreparePlugins
validatePlugins :: PluginPreparation :> es => [PreparedPlugin] -> Eff es (Either [Diagnostic] ValidationReport)
validatePlugins = send . ValidatePlugins
