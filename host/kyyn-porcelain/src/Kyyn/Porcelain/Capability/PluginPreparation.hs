{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.PluginPreparation
  ( PluginPreparation(..), PreparedPackage(..), PreparedPlugin(..), PreparedConnector(..), ConfiguredConnector(..), PreparedMethod(..)
  , preparePackages, preparePluginsFromGuest, preparePlugins, validatePlugins, instanceShape, selectedPackage, selectedPlugin, selectedInstance, sourceDetails ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Data.Coerce (coerce)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Guest (CheckedGuest)
import Kyyn.Domain.CompiledEntry (CompiledEntry)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport, errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Plugin (PluginName, pluginNameText, PackageIdentity, ConnectorTypeName(..), ConnectorName(..), BindingName, MethodName)
import Kyyn.Domain.Value (CheckedValue)

data PreparedConnector = PreparedConnector
  { connectorType :: ConnectorTypeName
  , configContract :: CheckedContract
  , payloadContract :: CheckedContract
  , fetchEntry :: CompiledEntry
  , validationEntry :: CompiledEntry
  , methods :: [PreparedMethod]
  , fetchOptionsContract :: Maybe CheckedContract
  , loginEntry :: Maybe CompiledEntry
  , syncPositionContract :: Maybe CheckedContract
  , reportContract :: Maybe CheckedContract
  }
  | PreparedSinkConnector
  { connectorType :: ConnectorTypeName
  , configContract :: CheckedContract
  , validationEntry :: CompiledEntry
  , sinkInputContract :: CheckedContract
  , sinkOptionsContract :: CheckedContract
  , sinkResultContract :: CheckedContract
  , sinkEntry :: CompiledEntry
  , sinkDefaultOptions :: CheckedValue
  }
  deriving (Eq, Show)
data PreparedMethod = PreparedMethod MethodName String CheckedContract CheckedContract CompiledEntry deriving (Eq, Show)
data ConfiguredConnector = ConfiguredConnector ConnectorName BindingName PreparedConnector CheckedValue deriving (Eq, Show)
data PreparedPackage = PreparedPackage PluginName PackageIdentity [PreparedConnector] deriving (Eq, Show)
data PreparedPlugin = PreparedPlugin PreparedPackage [ConfiguredConnector] deriving (Eq, Show)

sourceDetails :: PreparedConnector -> Either [Diagnostic]
  (ConnectorTypeName,CheckedContract,CompiledEntry,[PreparedMethod],Maybe CheckedContract,Maybe CompiledEntry,Maybe CheckedContract,Maybe CheckedContract)
sourceDetails PreparedConnector {connectorType = kind,payloadContract = payload,fetchEntry = entry,methods = ms,
  fetchOptionsContract = options,loginEntry = login,syncPositionContract = position,reportContract = report} = Right (kind,payload,entry,ms,options,login,position,report)
sourceDetails PreparedSinkConnector{} = Left [errorDiagnostic "plugin.source-required" "This operation requires a source connector, not a sink."]

data PluginPreparation :: Effect where
  PreparePackages :: FileTree -> PluginPreparation m (Either [Diagnostic] [PreparedPackage])
  PreparePlugins :: FileTree -> PluginPreparation m (Either [Diagnostic] [PreparedPlugin])
  PreparePluginsFromGuest :: FileTree -> CompiledProgram -> CheckedGuest -> PluginPreparation m (Either [Diagnostic] [PreparedPlugin])
  ValidatePlugins :: [PreparedPlugin] -> PluginPreparation m (Either [Diagnostic] ValidationReport)
type instance DispatchOf PluginPreparation = Dynamic

preparePackages :: PluginPreparation :> es => FileTree -> Eff es (Either [Diagnostic] [PreparedPackage])
preparePackages = send . PreparePackages

preparePlugins :: PluginPreparation :> es => FileTree -> Eff es (Either [Diagnostic] [PreparedPlugin])
preparePlugins = send . PreparePlugins
-- Root tools and their plugin methods share this already built executable.
preparePluginsFromGuest :: PluginPreparation :> es => FileTree -> CompiledProgram -> CheckedGuest
  -> Eff es (Either [Diagnostic] [PreparedPlugin])
preparePluginsFromGuest code program description = send (PreparePluginsFromGuest code program description)
validatePlugins :: PluginPreparation :> es => [PreparedPlugin] -> Eff es (Either [Diagnostic] ValidationReport)
validatePlugins = send . ValidatePlugins

instanceShape :: [(ConnectorTypeName,Shape)] -> Shape
instanceShape connectors = List (Record [("name",Scalar TextScalar),("binding",Scalar TextScalar),
  ("connector",Union [(coerce name,Just config) | (name,config) <- connectors])])

selectedPackage :: PluginName -> [PreparedPackage] -> Either [Diagnostic] PreparedPackage
selectedPackage name packages = case [package | package@(PreparedPackage actual _ _) <- packages, name == actual] of
  [package] -> Right package
  _ -> Left [errorDiagnostic "plugin.unknown" ("No installed plugin named " ++ pluginNameText name)]

selectedPlugin :: PluginName -> [PreparedPlugin] -> Either [Diagnostic] PreparedPlugin
selectedPlugin name plugins = case [plugin | plugin@(PreparedPlugin (PreparedPackage actual _ _) _) <- plugins, name == actual] of
  [plugin] -> Right plugin
  _ -> Left [errorDiagnostic "plugin.unknown" ("No installed plugin named " ++ pluginNameText name)]

selectedInstance :: PluginName -> ConnectorName -> [PreparedPlugin] -> Either [Diagnostic] (PreparedPackage,ConfiguredConnector)
selectedInstance plugin name plugins = do
  PreparedPlugin package instances <- selectedPlugin plugin plugins
  case [instanceValue | instanceValue@(ConfiguredConnector actual _ _ _) <- instances, actual == name] of
    [value] -> Right (package,value)
    _ -> Left [errorDiagnostic "plugin.instance-unknown" ("No configured connector " ++ pluginNameText plugin ++ "/" ++ coerce name)]
