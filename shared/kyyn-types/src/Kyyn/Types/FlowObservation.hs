module Kyyn.Types.FlowObservation
  ( FlowSummary(..), OperationIdentity(..), FlowObservation(..) ) where

import Agentic.Value (Value)

newtype FlowSummary = FlowSummary Value deriving (Eq, Show)
newtype OperationIdentity = OperationIdentity Value deriving (Eq, Show)
data FlowObservation = FlowObservation
  { summary :: FlowSummary, operation :: Maybe OperationIdentity }
  deriving (Eq, Show)
