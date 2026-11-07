{-# LANGUAGE GADTs, TypeFamilies, DataKinds, OverloadedRecordDot #-}
module Kyyn.Porcelain.Capability.GuestApi
  ( GuestApi(..), readCatalogue, listModules, findModule, findSymbol ) where

import qualified Data.Text as Text
import Effectful (Eff, Effect, (:>), DispatchOf, Dispatch(..))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.GuestApi

data GuestApi :: Effect where
  ReadCatalogue :: GuestApi m (Either [Diagnostic] [ApiModule])
type instance DispatchOf GuestApi = 'Dynamic

readCatalogue :: GuestApi :> es => Eff es (Either [Diagnostic] [ApiModule])
readCatalogue = send ReadCatalogue

listModules :: GuestApi :> es => Eff es (Either [Diagnostic] [String])
listModules = fmap (fmap (map (Text.unpack . moduleName))) readCatalogue

findModule :: GuestApi :> es => String -> Eff es (Either [Diagnostic] ApiModule)
findModule selected = fmap (>>= find) readCatalogue
  where
    find modules = case [m | m <- modules, Text.unpack m.moduleName == selected] of
      [m] -> Right m
      _ -> Left [errorDiagnostic "guest.module-not-found"
        ("Unknown guest module " ++ selected ++ "; use guest module list")]

findSymbol :: GuestApi :> es => String -> Eff es (Either [Diagnostic] (String,[ApiSymbol]))
findSymbol selected = fmap (>>= find) readCatalogue
  where
    find modules = case [(Text.unpack m.moduleName,s) | m <- modules, s <- m.moduleExports,
                               Text.unpack m.moduleName ++ "." ++ Text.unpack s.exportName == selected] of
      [] -> Left [errorDiagnostic "guest.symbol-not-found"
        ("Unknown guest symbol " ++ selected ++ "; use guest module show MODULE")]
      found@((m,_):_) -> Right (m,map snd found)
