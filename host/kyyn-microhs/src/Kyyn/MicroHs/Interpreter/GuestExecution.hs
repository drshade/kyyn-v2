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
import qualified Kyyn.Plumbing.Protocol.Frame as Wire

runGuestExecution :: (FileSystem :> es, Process.ProcessExecution :> es, Failure :> es)
  => GuestToolchain -> Eff (GuestExecution : es) a -> Eff es a
runGuestExecution (GuestToolchain toolchain) = interpret $ \env -> \case
  ExecuteCompiled (CompiledProgram _ (path, bytes)) input -> withTemporaryScope $ \scope -> do
    writeBytes scope path bytes
    Process.withProcess (Process.ProcessSpec (scopePath toolchain ++ "/bin/mhseval")
      ["+RTS", "-r" ++ relativeName path, "-RTS"] (scopePath scope)
      [("LC_ALL", "C.UTF-8"), ("PATH", "")]) $ do
        mapM_ Process.writeStdin (Wire.encodeFrame (Wire.jsonFrame input))
        Process.closeStdin
        output <- Process.collectStdout
        status <- Process.awaitExit
        let Process.ProcessExit code _ = status
        if code /= 0 then pure (Bytes.empty,status) else do
          (Wire.Frame metadata body,rest) <- Wire.readFrame (pure Nothing) output >>= either broken pure
          if Bytes.null body && Bytes.null rest then pure (metadata,status)
            else broken "Unexpected body or output after one-shot result"
  ExecuteGuest (CompiledProgram _ (path, bytes)) input respond ->
    localSeqUnlift env $ \unlift -> withTemporaryScope $ \scope -> do
      writeBytes scope path bytes
      Process.withProcess (Process.ProcessSpec (scopePath toolchain ++ "/bin/mhseval")
        ["+RTS", "-r" ++ relativeName path, "-RTS"] (scopePath scope)
        [("LC_ALL", "C.UTF-8"), ("PATH", "")]) $ do
          mapM_ Process.writeStdin (Wire.encodeFrame input)
          let loop buffered = do
                (line, rest) <- Wire.readFrame Process.readStdout buffered >>= either broken pure
                answer <- raise (unlift (respond line))
                case answer of
                  Just response -> do
                    mapM_ Process.writeStdin (Wire.encodeFrame response)
                    loop rest
                  Nothing -> do
                    Process.closeStdin
                    trailing <- Process.collectStdout
                    status <- Process.awaitExit
                    if Bytes.null (rest <> trailing) then pure (line,status)
                      else broken "Output follows the terminal guest frame"
          loop Bytes.empty

broken :: Failure :> es => String -> Eff es a
broken message = raiseFailure (RuntimeUnavailable (ProcessDiagnostic ReadOutput message))
