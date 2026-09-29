{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.PluginLogin (PluginLogin(..), loginPlugin) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Domain.Diagnostic (Diagnostic)

data PluginLogin :: Effect where
  LoginPlugin :: CompiledProgram -> CheckedValue -> PluginLogin m (Either [Diagnostic] ())
type instance DispatchOf PluginLogin = Dynamic

loginPlugin :: PluginLogin :> es => CompiledProgram -> CheckedValue -> Eff es (Either [Diagnostic] ())
loginPlugin program = send . LoginPlugin program
