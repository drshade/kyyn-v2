{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.PluginLogin (runPluginLogin) where

import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.HttpTransport (HttpTransport)
import Kyyn.Plumbing.Capability.SecretStore (SecretStore)
import Kyyn.Plumbing.Capability.PluginInteraction (Waiting, LoginInteraction)
import Kyyn.Porcelain.Capability.PluginLogin
import Kyyn.Porcelain.Protocol.PluginHost (executeLogin)

runPluginLogin :: (GuestExecution :> es, Failure :> es, HttpTransport :> es,
    SecretStore :> es, Waiting :> es, LoginInteraction :> es) => Eff (PluginLogin : es) a -> Eff es a
runPluginLogin = interpret $ \_ (LoginPlugin program (CheckedValue _ config)) -> executeLogin program config
