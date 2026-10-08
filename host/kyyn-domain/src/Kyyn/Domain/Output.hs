module Kyyn.Domain.Output (OutputDefinition(..), SinkReference(..), PublicationOutcome(..)) where

import Kyyn.Domain.Plugin (PluginName, ConnectorName, MethodName)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Value (CheckedValue)

data OutputDefinition = OutputDefinition String String String SinkReference deriving (Eq, Show)
data SinkReference = SinkReference PluginName ConnectorName MethodName deriving (Eq, Show)
data PublicationOutcome = Acknowledged CheckedValue | RejectedByDestination Diagnostic
  | FailedBeforeDispatch Diagnostic | Uncertain Diagnostic deriving (Eq, Show)
