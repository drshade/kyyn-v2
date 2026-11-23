{-# LANGUAGE OverloadedRecordDot #-}
module Kyyn.Porcelain.Protocol.EventBindings (checkEventBindings) where

import Control.Monad (unless, forM_)
import qualified Data.Text as Text
import Kyyn.Domain.Contract (contractId)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Plugin (pluginName, connectorName, ConnectorTypeName(..), MethodName(..))
import Kyyn.Types.Contract (fingerprint)
import Kyyn.Types.KnowledgeBase (EventReference(..))
import Kyyn.Porcelain.Capability.PluginPreparation

checkEventBindings :: [EventReference] -> [PreparedPlugin] -> Either [Diagnostic] ()
checkEventBindings refs plugins = forM_ refs $ \ref -> do
  let label = Text.unpack (ref.plugin <> "/" <> ref.instanceName <> "/" <> ref.method)
      bad message = Left [errorDiagnostic "flow.event-binding" (label ++ ": " ++ message)]
      named = either bad Right
  pluginKey <- named (pluginName (Text.unpack ref.plugin))
  selectedName <- named (connectorName (Text.unpack ref.instanceName))
  (_,ConfiguredConnector _ _ selectedConnector _) <- selectedInstance pluginKey selectedName plugins
  case selectedConnector of
    PreparedEventConnector {connectorType = ConnectorTypeName kind,events = events} -> do
      unless (Text.pack kind == ref.connector) (bad "Configured connector type differs from the declared event")
      case [selectedMethod | selectedMethod@(PreparedEvent (MethodName name) _ _ _ _ _ _ _) <- events, Text.pack name == ref.method] of
        [PreparedEvent _ _ _ request reply _ _ _] -> do
          unless (fingerprint (contractId request) == ref.requestContract) (bad "Declared request contract differs from the checked poll")
          unless (fingerprint (contractId reply) == ref.replyContract) (bad "Declared reply contract differs from the checked poll")
        _ -> bad "No unique declared event in the configured connector"
    _ -> bad "Configured connector is not an event connector"
