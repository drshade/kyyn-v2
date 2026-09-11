{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Plumbing.Capability.ApiInspection (ApiInspection(..), inspectApiModules) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.GuestApi (ApiModule)

data ApiInspection :: Effect where
  InspectApiModules :: FileTree -> [String] -> ApiInspection m (Either [Diagnostic] [ApiModule])

type instance DispatchOf ApiInspection = Dynamic

inspectApiModules :: ApiInspection :> es
  => FileTree -> [String] -> Eff es (Either [Diagnostic] [ApiModule])
inspectApiModules sources = send . InspectApiModules sources
