{-# LANGUAGE DataKinds, LambdaCase, GADTs #-}
module Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO) where

import Control.Concurrent.Async (Async, async, cancel, wait)
import Control.Exception (IOException, displayException)
import qualified Data.ByteString as Bytes
import Effectful (Eff, IOE, (:>), liftIO, UnliftStrategy(..))
import Effectful.Dispatch.Dynamic (interpret, localLiftUnlift)
import qualified Effectful.Exception as Exception
import Kyyn.Domain.Failure
import Kyyn.Plumbing.Capability.Failure
import Kyyn.Plumbing.Capability.ProcessExecution
import System.IO (Handle, hClose, hFlush)
import qualified System.Process.Typed as Process

runProcessExecutionIO
  :: (IOE :> es, Failure :> es)
  => Eff (ProcessExecution : es) a -> Eff es a
runProcessExecutionIO = interpret $ \env (WithProcess spec action) ->
  localLiftUnlift env SeqUnlift $ \liftLocal unlift ->
    Exception.bracket
      (native StartProcess (Process.startProcess (configuration spec)))
      (native StopProcess . Process.stopProcess)
      (\child -> Exception.bracket
        (liftIO (async (Bytes.hGetContents (Process.getStderr child))))
        (liftIO . cancel)
        (\errors -> unlift (interpret (\_ op -> liftLocal (handlePipe child errors op)) action)))

configuration :: ProcessSpec -> Process.ProcessConfig Handle Handle Handle
configuration ProcessSpec{executable, arguments, workingDirectory, environment} =
  Process.setStdin Process.createPipe
    . Process.setStdout Process.createPipe
    . Process.setStderr Process.createPipe
    . Process.setWorkingDir workingDirectory
    . Process.setEnv environment
    $ Process.proc executable arguments

handlePipe
  :: (IOE :> es, Failure :> es)
  => Process.Process Handle Handle Handle
  -> Async Bytes.ByteString
  -> ProcessPipes m a -> Eff es a
handlePipe child errors = \case
  WriteStdin bytes -> native WriteInput $ Bytes.hPut (Process.getStdin child) bytes >> hFlush (Process.getStdin child)
  CloseStdin -> native CloseInput $ hClose (Process.getStdin child)
  ReadStdout -> native ReadOutput $ do
    chunk <- Bytes.hGetSome (Process.getStdout child) 32768
    pure (if Bytes.null chunk then Nothing else Just chunk)
  AwaitExit -> native WaitForExit $ do
    status <- Process.waitExitCode child
    diagnostics <- wait errors
    pure (ProcessExit (case status of Process.ExitSuccess -> 0; Process.ExitFailure code -> code) diagnostics)

native :: (IOE :> es, Failure :> es) => ProcessOperation -> IO a -> Eff es a
native operation action = liftIO action `Exception.catch` \(err :: IOException) ->
  raiseFailure (RuntimeUnavailable (ProcessDiagnostic operation (displayException err)))
