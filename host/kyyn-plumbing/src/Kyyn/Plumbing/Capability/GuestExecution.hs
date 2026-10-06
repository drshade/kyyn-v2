{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.GuestExecution (GuestExecution(..), executeGuest, executeCompiled, executeCompiledEntry) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Data.ByteString (ByteString)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit(..))
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Protocol.Frame (Frame)

data GuestExecution :: Effect where
  ExecuteCompiled :: CompiledProgram -> ByteString -> GuestExecution m (ByteString, ProcessExit)
  ExecuteGuest :: CompiledProgram -> Frame -> (Frame -> m (Maybe Frame))
    -> GuestExecution m (Frame, ProcessExit)

type instance DispatchOf GuestExecution = Dynamic

executeGuest :: GuestExecution :> es => CompiledProgram -> Frame
  -> (Frame -> Eff es (Maybe Frame)) -> Eff es (Frame, ProcessExit)
executeGuest program input respond = send (ExecuteGuest program input respond)

executeCompiled :: GuestExecution :> es
  => CompiledProgram -> ByteString -> Eff es (ByteString, ProcessExit)
executeCompiled entry = send . ExecuteCompiled entry

executeCompiledEntry :: (GuestExecution :> es, Failure :> es)
  => String -> CompiledProgram -> ByteString -> Eff es ByteString
executeCompiledEntry selected entry input = do
  (output, ProcessExit status diagnostics) <- executeCompiled entry input
  if status /= 0
    then raiseFailure (RuntimeUnavailable (ProcessDiagnostic WaitForExit
      (selected ++ " exited " ++ show status ++ ": " ++ show diagnostics)))
    else pure output
