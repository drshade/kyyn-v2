{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.GuestCompilation
  ( GuestCompilation(..), compileGuest, withCompiledEntry
  , GuestSources, guestSources, sourceFiles, selectedEntry, sourceIdentity
  , BuildIdentity(..), CompiledEntry, buildIdentity ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Path (scopePath)
import Kyyn.Plumbing.Capability.FileSystem
import Kyyn.Plumbing.Capability.GuestCompilation.Types
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process

data GuestCompilation :: Effect where
  CompileGuest :: GuestSources -> GuestCompilation m (Either [Diagnostic] CompiledEntry)

type instance DispatchOf GuestCompilation = Dynamic

compileGuest :: GuestCompilation :> es => GuestSources -> Eff es (Either [Diagnostic] CompiledEntry)
compileGuest = send . CompileGuest

buildIdentity :: CompiledEntry -> BuildIdentity
buildIdentity CompiledEntry{identity} = identity

withCompiledEntry
  :: (FileSystem :> es, Process.ProcessExecution :> es)
  => CompiledEntry -> Eff (Process.ProcessPipes : es) a -> Eff es a
withCompiledEntry CompiledEntry{artifact = (path, bytes), evaluator, arguments, environment} action =
  withTemporaryScope $ \scope -> do
    writeBytes scope path bytes
    Process.withProcess (Process.ProcessSpec evaluator arguments (scopePath scope) environment) action
