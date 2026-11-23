{-# LANGUAGE OverloadedRecordDot, TypeApplications, DataKinds #-}
-- | Reconstruct configured dispatch handles from an already checked description.
module Kyyn.Porcelain.Protocol.PluginDescription (connectorDescription) where

import Data.Aeson (Value)
import qualified Data.Text as Text
import GHC.Records (getField)
import Kyyn.Domain.CompiledEntry (CompiledConnector(..))
import Kyyn.Domain.Evidence (validateReportContract)
import Kyyn.Domain.Contract (contractId)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Guest (InspectedSchema(..))
import Kyyn.Domain.Plugin (connectorTypeName, methodName)
import Kyyn.Domain.Value (CheckedValue(..))
import qualified Kyyn.Types.Guest as G
import Kyyn.Porcelain.Capability.PluginPreparation

-- Sink defaults are captured once during preparation, never recomputed on reopen.
-- The caller checks their value against the options contract before dispatch.
connectorDescription :: CompiledConnector -> Maybe Value -> Either [Diagnostic] PreparedConnector
connectorDescription selected defaults = case selected of
  CompiledSource identity contracts acquisition validator login captured -> do
    kind <- checked (connectorTypeName (Text.unpack identity.connectorType))
    let (config,options,payload,position,report) = case contracts of
          G.StatelessContracts c o p -> (c,o,p,Nothing,Nothing)
          G.StatefulContracts c o p s r -> (c,o,p,Just s,Just r)
    mapM_ (checked . validateReportContract . getField @"contract") report
    methods <- traverse (\(method,entry) -> do
      name <- checked (methodName (Text.unpack method.capturedName))
      let G.CapturedContracts input _ result = method.capturedInvocation.invocationContract
      pure (PreparedMethod name (Text.unpack method.capturedDescription) input.contract result.contract entry)) captured
    case defaults of
      Just _ -> bad "Source connector cannot have sink defaults"
      Nothing -> pure (PreparedConnector kind config.contract payload.contract acquisition validator methods
        (getField @"contract" <$> options) login (getField @"contract" <$> position) (getField @"contract" <$> report))
  CompiledSink identity (G.SinkContracts config options input result) publication validator _ -> do
    kind <- checked (connectorTypeName (Text.unpack identity.connectorType))
    value <- maybe (bad ("Missing captured defaults for " ++ Text.unpack identity.connectorType)) Right defaults
    pure (PreparedSinkConnector kind config.contract validator input.contract options.contract result.contract publication
      (CheckedValue (contractId options.contract) value))
  CompiledEvent identity config validator login events -> do
    kind <- checked (connectorTypeName (Text.unpack identity.connectorType))
    selectedEvents <- traverse (\(event,poll,dispatch) -> do
      name <- checked (methodName (Text.unpack event.eventName))
      let G.EventContracts _ request cursor reply = event.eventPoll.invocationContract
      pure (PreparedEvent name (Text.unpack event.eventDescription) event.minimumPollInterval
        request.contract reply.contract cursor.contract poll ((,) <$> dispatch <*> (snd <$> event.eventDispatch)))) events
    case defaults of
      Just _ -> bad "Event connector cannot have sink defaults"
      Nothing -> pure (PreparedEventConnector kind config.contract validator login selectedEvents)
  where
    checked = either bad Right
    bad message = Left [errorDiagnostic "flow.connector-description" message]
