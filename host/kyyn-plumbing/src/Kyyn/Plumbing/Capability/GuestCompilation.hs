{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.GuestCompilation
  ( GuestCompilation(..), compileGuest, executeCompiled, executeCompiledEntry
  , GuestSources, guestSources, sourceFiles, selectedEntry, sourceIdentity
  , BuildIdentity(..), CompiledProgram(..) ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Data.ByteString (ByteString)
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.CompiledProgram (BuildIdentity(..), CompiledProgram(..))
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.GuestCompilation.Types
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process

data GuestCompilation :: Effect where
  CompileGuest :: GuestSources -> GuestCompilation m (Either [Diagnostic] CompiledProgram)
  ExecuteCompiled :: CompiledProgram -> ByteString -> GuestCompilation m (ByteString, Process.ProcessExit)

type instance DispatchOf GuestCompilation = Dynamic

compileGuest :: GuestCompilation :> es => GuestSources -> Eff es (Either [Diagnostic] CompiledProgram)
compileGuest = send . CompileGuest

executeCompiled :: GuestCompilation :> es
  => CompiledProgram -> ByteString -> Eff es (ByteString, Process.ProcessExit)
executeCompiled entry = send . ExecuteCompiled entry

executeCompiledEntry :: (GuestCompilation :> es, Failure :> es)
  => String -> CompiledProgram -> ByteString -> Eff es ByteString
executeCompiledEntry selected entry input = do
  (output, Process.ProcessExit status diagnostics) <- executeCompiled entry input
  if status /= 0
    then raiseFailure (RuntimeUnavailable (ProcessDiagnostic WaitForExit
      (selected ++ " exited " ++ show status ++ ": " ++ show diagnostics)))
    else pure output
