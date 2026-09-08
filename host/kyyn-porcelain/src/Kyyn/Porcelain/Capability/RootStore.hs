{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RootStore
  ( RootStore(..), checkRootValue, materializeRoot, loadRootValueForChecking ) where

import Data.Aeson (Value)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Root (Root, CheckedValue)
import Kyyn.Domain.FileTree (FileTree)

data RootStore :: Effect where
  CheckRootValue :: CheckedContract -> Value -> RootStore m (Either [Diagnostic] CheckedValue)
  MaterializeRoot :: CheckedContract -> FileTree -> CheckedValue -> RootStore m (Either [Diagnostic] Root)
  LoadRootValueForChecking :: Root -> RootStore m (Either [Diagnostic] CheckedValue)

type instance DispatchOf RootStore = Dynamic

checkRootValue :: RootStore :> es => CheckedContract -> Value -> Eff es (Either [Diagnostic] CheckedValue)
checkRootValue contract = send . CheckRootValue contract

materializeRoot :: RootStore :> es => CheckedContract -> FileTree -> CheckedValue -> Eff es (Either [Diagnostic] Root)
materializeRoot contract code = send . MaterializeRoot contract code

loadRootValueForChecking :: RootStore :> es => Root -> Eff es (Either [Diagnostic] CheckedValue)
loadRootValueForChecking = send . LoadRootValueForChecking
