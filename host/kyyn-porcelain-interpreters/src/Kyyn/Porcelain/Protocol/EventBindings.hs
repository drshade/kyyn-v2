{-# LANGUAGE OverloadedRecordDot #-}
module Kyyn.Porcelain.Protocol.EventBindings (checkEventBindings, resolveEventBinding, checkEventWait) where

import Control.Monad (unless, void, forM_)
import Kyyn.Types.EventWait (EventWaitRequest(..))
import Kyyn.Domain.Contract (descriptionOf)
import qualified Data.Text as Text
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Plugin (pluginName, connectorName, ConnectorTypeName(..), MethodName(..))
import Kyyn.Types.KnowledgeBase (EventReference(..))
import Kyyn.Porcelain.Capability.PluginPreparation

checkEventBindings :: [EventReference] -> [PreparedPlugin] -> Either [Diagnostic] ()
checkEventBindings refs plugins = forM_ refs (\ref -> void (resolveEventBinding ref plugins))

resolveEventBinding :: EventReference -> [PreparedPlugin] -> Either [Diagnostic] PreparedEvent
resolveEventBinding ref plugins = do
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
        [selectedMethod] -> pure selectedMethod
        _ -> bad "No unique declared event in the configured connector"
    _ -> bad "Configured connector is not an event connector"

-- Identity and type agreement concern this captured execution, not compatibility
-- with any previous plugin or recipe revision.
checkEventWait :: [EventReference] -> [PreparedPlugin] -> EventWaitRequest -> Either [Diagnostic] PreparedEvent
checkEventWait permitted plugins request = do
  let ref = request.binding
      bad message = Left [errorDiagnostic "flow.event-binding"
        (Text.unpack (ref.plugin <> "/" <> ref.instanceName <> "/" <> ref.method) ++ ": " ++ message)]
  unless (ref `elem` permitted) (bad "Event is outside this instance's captured declarations; start a new instance from the updated recipe")
  event@(PreparedEvent _ _ _ input output _ _ _) <- resolveEventBinding ref plugins
  unless (descriptionOf input == request.requestContract && descriptionOf output == request.replyContract)
    (bad "Event request or reply contract differs from the captured connector")
  pure event
