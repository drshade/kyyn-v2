{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.GuestApi (runGuestApi, runGuestApiFromCatalogue) where

import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.GuestApi (ApiModule)
import Kyyn.Plumbing.Capability.ApiInspection (ApiInspection, inspectApiModules)
import Kyyn.Porcelain.Capability.GuestApi (GuestApi(..))

runGuestApiFromCatalogue :: Either [Diagnostic] [ApiModule] -> Eff (GuestApi : es) a -> Eff es a
runGuestApiFromCatalogue catalogue = interpret $ \_ ReadCatalogue -> pure catalogue

-- The selected KB lock owns its libraries and discovery; there is no installed
-- host catalogue to substitute when the selected source fails to build.
runGuestApi :: ApiInspection :> es
  => FileTree -> [String] -> Eff (GuestApi : es) a -> Eff es a
runGuestApi sources modules = interpret $ \_ ReadCatalogue -> inspectApiModules sources modules
