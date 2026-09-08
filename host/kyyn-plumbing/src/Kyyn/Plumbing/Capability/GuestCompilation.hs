{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.GuestCompilation
  ( GuestCompilation(..), compileGuest, withCompiledEntry, executeCompiledEntry
  , GuestSources, guestSources, sourceFiles, selectedEntry, sourceIdentity
  , BuildIdentity(..), CompiledEntry, buildIdentity ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Data.ByteString (ByteString)
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Domain.Path (scopePath)
import Kyyn.Plumbing.Capability.FileSystem
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
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

executeCompiledEntry :: (FileSystem :> es, Process.ProcessExecution :> es, Failure :> es)
  => String -> CompiledEntry -> ByteString -> Eff es ByteString
executeCompiledEntry selected entry input = withCompiledEntry entry $ do
  Process.writeStdin input
  Process.closeStdin
  output <- Process.collectStdout
  Process.ProcessExit status diagnostics <- Process.awaitExit
  if status /= 0
    then raiseFailure (RuntimeUnavailable (ProcessDiagnostic WaitForExit
      (selected ++ " exited " ++ show status ++ ": " ++ show diagnostics)))
    else pure output
