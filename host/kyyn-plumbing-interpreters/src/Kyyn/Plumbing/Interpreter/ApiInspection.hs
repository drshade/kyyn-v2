{-# LANGUAGE GADTs, OverloadedRecordDot #-}
module Kyyn.Plumbing.Interpreter.ApiInspection (runApiInspection) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (nub, sort)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Guest (checkedEntries, checkedModules)
import Kyyn.Types.Guest (moduleName)
import Kyyn.Plumbing.Capability.ApiInspection
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestInspection

runApiInspection :: (GuestCompilation :> es, GuestInspection :> es)
  => Eff (ApiInspection : es) a -> Eff es a
runApiInspection = interpret $ \_ (InspectApiModules sources names) -> runExceptT $ do
  let selected = map Text.pack (nub names)
  captured <- either (throwE . pure . errorDiagnostic "guest.api-source") pure
    (guestSources (DiscoveryEntries (ModuleExports selected)) (files sources))
  program <- ExceptT (compileGuest captured)
  described <- ExceptT (describeGuest program)
  unless (null (checkedEntries described) && sort (map moduleName (checkedModules described)) == sort selected)
    (throwE [errorDiagnostic "guest.api-selection" "API discovery did not return exactly the selected modules"])
  pure (checkedModules described)
