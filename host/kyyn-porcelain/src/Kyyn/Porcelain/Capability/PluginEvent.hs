{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.PluginEvent (PluginEvent(..), dispatchEvent, pollEvent) where

import Data.Aeson (Value)
import Data.Text (Text)
import Kyyn.Types.EventIdentity (EventIdentity)
import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.CompiledEntry (CompiledEntry)
import Kyyn.Domain.Diagnostic (Diagnostic)

data PluginEvent :: Effect where
  DispatchEvent :: CompiledEntry -> Value -> Text -> Value -> PluginEvent m (Either [Diagnostic] Value)
  PollEvent :: CompiledEntry -> Value -> Text -> Value -> Maybe Value
    -> PluginEvent m (Either [Diagnostic] ([(EventIdentity,Value)],Value))
type instance DispatchOf PluginEvent = Dynamic

dispatchEvent :: PluginEvent :> es => CompiledEntry -> Value -> Text -> Value -> Eff es (Either [Diagnostic] Value)
dispatchEvent entry config identity = send . DispatchEvent entry config identity

pollEvent :: PluginEvent :> es => CompiledEntry -> Value -> Text -> Value -> Maybe Value
  -> Eff es (Either [Diagnostic] ([(EventIdentity,Value)],Value))
pollEvent entry config identity request = send . PollEvent entry config identity request
