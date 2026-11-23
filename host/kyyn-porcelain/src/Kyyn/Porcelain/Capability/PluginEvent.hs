{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.PluginEvent (PluginEvent(..), dispatchEvent) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.CompiledEntry (CompiledEntry)
import Kyyn.Domain.Diagnostic (Diagnostic)

data PluginEvent :: Effect where
  DispatchEvent :: CompiledEntry -> Value -> Text -> Value -> PluginEvent m (Either [Diagnostic] Value)
type instance DispatchOf PluginEvent = Dynamic

dispatchEvent :: PluginEvent :> es => CompiledEntry -> Value -> Text -> Value -> Eff es (Either [Diagnostic] Value)
dispatchEvent entry config identity = send . DispatchEvent entry config identity
