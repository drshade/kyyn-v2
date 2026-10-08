{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.Delivery (Delivery(..), invokeSink) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Domain.Output (PublicationOutcome)
import Kyyn.Porcelain.Capability.PluginPreparation (ConfiguredConnector)

data Delivery :: Effect where
  InvokeSink :: ConfiguredConnector -> CheckedValue -> CheckedValue -> Delivery m PublicationOutcome
type instance DispatchOf Delivery = Dynamic

invokeSink :: Delivery :> es => ConfiguredConnector -> CheckedValue -> CheckedValue -> Eff es PublicationOutcome
invokeSink connector options = send . InvokeSink connector options
