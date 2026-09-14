{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.PluginPreparation
  ( PluginPreparation(..), PreparedPackage(..), PreparedPlugin(..), PreparedConnector(..), ConfiguredConnector(..)
  , preparePackages, preparePlugins, validatePlugins, instanceShape ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Data.Coerce (coerce)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Plugin (PluginName, PackageIdentity, ConnectorTypeName(..), ConnectorName, BindingName)
import Kyyn.Domain.Value (CheckedValue)

data PreparedConnector = PreparedConnector
  { connectorType :: ConnectorTypeName
  , configContract :: CheckedContract
  , payloadContract :: CheckedContract
  , fetchEntry :: CompiledProgram
  , validationEntry :: CompiledProgram
  }
  deriving (Eq, Show)
data ConfiguredConnector = ConfiguredConnector ConnectorName BindingName PreparedConnector CheckedValue deriving (Eq, Show)
data PreparedPackage = PreparedPackage PluginName PackageIdentity [PreparedConnector] deriving (Eq, Show)
data PreparedPlugin = PreparedPlugin PreparedPackage [ConfiguredConnector] deriving (Eq, Show)

data PluginPreparation :: Effect where
  PreparePackages :: FileTree -> PluginPreparation m (Either [Diagnostic] [PreparedPackage])
  PreparePlugins :: FileTree -> PluginPreparation m (Either [Diagnostic] [PreparedPlugin])
  ValidatePlugins :: [PreparedPlugin] -> PluginPreparation m (Either [Diagnostic] ValidationReport)
type instance DispatchOf PluginPreparation = Dynamic

preparePackages :: PluginPreparation :> es => FileTree -> Eff es (Either [Diagnostic] [PreparedPackage])
preparePackages = send . PreparePackages

preparePlugins :: PluginPreparation :> es => FileTree -> Eff es (Either [Diagnostic] [PreparedPlugin])
preparePlugins = send . PreparePlugins
validatePlugins :: PluginPreparation :> es => [PreparedPlugin] -> Eff es (Either [Diagnostic] ValidationReport)
validatePlugins = send . ValidatePlugins

instanceShape :: [(ConnectorTypeName,Shape)] -> Shape
instanceShape connectors = List (Record [("name",Scalar TextScalar),("binding",Scalar TextScalar),
  ("connector",Union [(coerce name,Just config) | (name,config) <- connectors])])
