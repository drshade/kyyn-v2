{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.PluginLive (PluginLive(..), executeLiveQuery) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Data.Aeson (Value)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Types.Plugin (FetchError)
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedMethod)

data PluginLive :: Effect where
  ExecuteLiveQuery :: CheckedValue -> PreparedMethod -> Value
    -> PluginLive m (Either [Diagnostic] (Either FetchError CheckedValue))
type instance DispatchOf PluginLive = Dynamic

executeLiveQuery :: PluginLive :> es => CheckedValue -> PreparedMethod -> Value
  -> Eff es (Either [Diagnostic] (Either FetchError CheckedValue))
executeLiveQuery config method = send . ExecuteLiveQuery config method
