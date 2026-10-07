module Kyyn.Porcelain.Protocol.ToolBindings (pluginBindings) where

import Kyyn.Domain.Contract (rootType)
import Kyyn.Plumbing.Protocol.Tool (ConnectorInterface(..), InstanceBinding(..))
import Kyyn.Porcelain.Capability.PluginPreparation

pluginBindings :: [PreparedPlugin] -> ([ConnectorInterface],[InstanceBinding])
pluginBindings plugins = (interfaces,bindings)
  where
    interfaces = [ConnectorInterface plugin kind (rootType payload) [(name,rootType input,rootType output) | PreparedMethod name _ input output _ <- methods]
      | PreparedPlugin (PreparedPackage plugin _ connectors) _ <- plugins,
        PreparedConnector {connectorType = kind, payloadContract = payload, methods = methods} <- connectors]
    bindings = [InstanceBinding binding plugin kind name | PreparedPlugin (PreparedPackage plugin _ _) instances <- plugins,
      ConfiguredConnector name binding (PreparedConnector {connectorType = kind}) _ <- instances]
