{-# LANGUAGE GHC2021, DataKinds, GADTs, LambdaCase #-}
{-# OPTIONS_GHC -Werror #-}
module Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution) where

import qualified Data.ByteString as Bytes
import Effectful (Eff, (:>), raise)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift)
import Kyyn.Domain.CompiledProgram (CompiledProgram(..))
import Kyyn.Domain.Path (scopePath, relativeName)
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.Plumbing.Capability.FileSystem
import Kyyn.Plumbing.Capability.GuestExecution
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process

runGuestExecution :: (FileSystem :> es, Process.ProcessExecution :> es, Failure :> es)
  => GuestToolchain -> Eff (GuestExecution : es) a -> Eff es a
runGuestExecution (GuestToolchain toolchain) = interpret $ \env -> \case
  ExecuteCompiled (CompiledProgram _ (path, bytes)) input -> withTemporaryScope $ \scope -> do
    writeBytes scope path bytes
    Process.withProcess (Process.ProcessSpec (scopePath toolchain ++ "/bin/mhseval")
      ["+RTS", "-r" ++ relativeName path, "-RTS"] (scopePath scope)
      [("LC_ALL", "C.UTF-8"), ("PATH", "")]) $ do
        Process.writeStdin input
        Process.closeStdin
        output <- Process.collectStdout
        status <- Process.awaitExit
        pure (output, status)
  ExecuteGuest (CompiledProgram _ (path, bytes)) input respond ->
    localSeqUnlift env $ \unlift -> withTemporaryScope $ \scope -> do
      writeBytes scope path bytes
      Process.withProcess (Process.ProcessSpec (scopePath toolchain ++ "/bin/mhseval")
        ["+RTS", "-r" ++ relativeName path, "-RTS"] (scopePath scope)
        [("LC_ALL", "C.UTF-8"), ("PATH", "")]) $ do
          Process.writeStdin (input <> Bytes.singleton 10)
          let loop buffered = do
                (line, rest) <- frame buffered
                answer <- raise (unlift (respond line))
                case answer of
                  Just response -> do
                    Process.writeStdin (response <> Bytes.singleton 10)
                    loop rest
                  Nothing -> do
                    Process.closeStdin
                    trailing <- Process.collectStdout
                    status <- Process.awaitExit
                    if Bytes.null (rest <> trailing) then pure (line,status)
                      else broken "Output follows the terminal guest frame"
          loop Bytes.empty

frame :: (Process.ProcessPipes :> es, Failure :> es) => Bytes.ByteString -> Eff es (Bytes.ByteString, Bytes.ByteString)
frame buffered = case Bytes.elemIndex 10 buffered of
  Just index -> pure (Bytes.take index buffered, Bytes.drop (index + 1) buffered)
  Nothing -> Process.readStdout >>= maybe (broken "Guest exited without a complete terminal frame") (frame . (buffered <>))

broken :: Failure :> es => String -> Eff es a
broken message = raiseFailure (RuntimeUnavailable (ProcessDiagnostic ReadOutput message))
