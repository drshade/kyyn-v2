{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RootStore
  ( RootStore(..), readRootDefinition, checkRootValue, materializeRoot, loadRootValueForChecking ) where

import Data.Aeson (Value)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Root (Root, RootDefinition, CheckedValue)
import Kyyn.Domain.FileTree (FileTree)

data RootStore :: Effect where
  ReadRootDefinition :: FileTree -> RootStore m (Either [Diagnostic] RootDefinition)
  CheckRootValue :: RootContract -> Value -> RootStore m (Either [Diagnostic] CheckedValue)
  MaterializeRoot :: RootContract -> FileTree -> CheckedValue -> RootStore m (Either [Diagnostic] Root)
  LoadRootValueForChecking :: Root -> RootStore m (Either [Diagnostic] CheckedValue)

type instance DispatchOf RootStore = Dynamic

readRootDefinition :: RootStore :> es => FileTree -> Eff es (Either [Diagnostic] RootDefinition)
readRootDefinition = send . ReadRootDefinition

checkRootValue :: RootStore :> es => RootContract -> Value -> Eff es (Either [Diagnostic] CheckedValue)
checkRootValue contract = send . CheckRootValue contract

materializeRoot :: RootStore :> es => RootContract -> FileTree -> CheckedValue -> Eff es (Either [Diagnostic] Root)
materializeRoot contract code = send . MaterializeRoot contract code

loadRootValueForChecking :: RootStore :> es => Root -> Eff es (Either [Diagnostic] CheckedValue)
loadRootValueForChecking = send . LoadRootValueForChecking
