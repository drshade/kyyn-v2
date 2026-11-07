{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.GuestInspection (GuestInspection(..), describeGuest) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Guest (CheckedGuest)

data GuestInspection :: Effect where
  DescribeGuest :: CompiledProgram -> GuestInspection m (Either [Diagnostic] CheckedGuest)

type instance DispatchOf GuestInspection = Dynamic

describeGuest :: GuestInspection :> es => CompiledProgram -> Eff es (Either [Diagnostic] CheckedGuest)
describeGuest = send . DescribeGuest
