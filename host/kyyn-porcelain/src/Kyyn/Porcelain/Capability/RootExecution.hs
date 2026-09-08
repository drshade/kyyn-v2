{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RootExecution (RootExecution(..), validateRoot) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport)
import Kyyn.Domain.Root (Root)

data RootExecution :: Effect where
  ValidateRoot :: Root -> RootExecution m (Either [Diagnostic] ValidationReport)

type instance DispatchOf RootExecution = Dynamic

validateRoot :: RootExecution :> es => Root -> Eff es (Either [Diagnostic] ValidationReport)
validateRoot = send . ValidateRoot
