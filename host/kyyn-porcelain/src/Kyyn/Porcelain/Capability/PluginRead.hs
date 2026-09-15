{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.PluginRead (PluginRead(..), callCapturedMethod) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Data.Aeson (Value)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evidence (ConnectorInstanceRef, EvidenceProducer)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedMethod)

data PluginRead :: Effect where
  CallCapturedMethod :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> PreparedMethod -> Value
    -> PluginRead m (Either [Diagnostic] CheckedValue)
type instance DispatchOf PluginRead = Dynamic

callCapturedMethod :: PluginRead :> es
  => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> PreparedMethod -> Value
  -> Eff es (Either [Diagnostic] CheckedValue)
callCapturedMethod instanceRef producer payload method = send . CallCapturedMethod instanceRef producer payload method
