{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RootStore
  ( RootStore(..), readRootDefinition, checkRootValue, materializeRoot, loadRootValueForChecking
  , readExamples, encodeExample ) where

import Data.Aeson (Value)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Root (Root, RootDefinition, CheckedValue)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Example (Example)
import Kyyn.Domain.Query (QueryDescriptor)

data RootStore :: Effect where
  ReadRootDefinition :: FileTree -> RootStore m (Either [Diagnostic] RootDefinition)
  CheckRootValue :: RootContract -> Value -> RootStore m (Either [Diagnostic] CheckedValue)
  MaterializeRoot :: RootContract -> FileTree -> CheckedValue -> RootStore m (Either [Diagnostic] Root)
  LoadRootValueForChecking :: Root -> RootStore m (Either [Diagnostic] CheckedValue)
  ReadExamples :: Root -> [QueryDescriptor] -> RootStore m (Either [Diagnostic] [Example])
  EncodeExample :: Example -> RootStore m (Either [Diagnostic] FileTree)

type instance DispatchOf RootStore = Dynamic

readRootDefinition :: RootStore :> es => FileTree -> Eff es (Either [Diagnostic] RootDefinition)
readRootDefinition = send . ReadRootDefinition

checkRootValue :: RootStore :> es => RootContract -> Value -> Eff es (Either [Diagnostic] CheckedValue)
checkRootValue contract = send . CheckRootValue contract

materializeRoot :: RootStore :> es => RootContract -> FileTree -> CheckedValue -> Eff es (Either [Diagnostic] Root)
materializeRoot contract code = send . MaterializeRoot contract code

loadRootValueForChecking :: RootStore :> es => Root -> Eff es (Either [Diagnostic] CheckedValue)
loadRootValueForChecking = send . LoadRootValueForChecking

readExamples :: RootStore :> es => Root -> [QueryDescriptor] -> Eff es (Either [Diagnostic] [Example])
readExamples root = send . ReadExamples root

encodeExample :: RootStore :> es => Example -> Eff es (Either [Diagnostic] FileTree)
encodeExample = send . EncodeExample
