{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.GuestCompilation
  ( GuestCompilation(..), compileGuest
  , GuestSources, guestSources, sourceFiles, selectedEntry, sourceIdentity
  , BuildIdentity(..), CompiledProgram(..) ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.CompiledProgram (BuildIdentity(..), CompiledProgram(..))
import Kyyn.Plumbing.Capability.GuestCompilation.Types

data GuestCompilation :: Effect where
  CompileGuest :: GuestSources -> GuestCompilation m (Either [Diagnostic] CompiledProgram)

type instance DispatchOf GuestCompilation = Dynamic

compileGuest :: GuestCompilation :> es => GuestSources -> Eff es (Either [Diagnostic] CompiledProgram)
compileGuest = send . CompileGuest
