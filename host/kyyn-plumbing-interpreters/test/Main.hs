-- Native process lifetime/pipe exchange, failure, cancellation and filesystem tests.
-- Process reaping assertions require POSIX; no MicroHs compilation.

{-# LANGUAGE DataKinds, OverloadedStrings #-}
module Main (main) where

import Control.Concurrent (threadDelay, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (withAsync, cancel, waitCatch)
import Control.Exception (IOException, SomeException, try, throwIO)
import Control.Monad (unless, forever)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Effectful (Eff, IOE, (:>), runEff, liftIO)
import Effectful.State.Static.Local (runState, modify)
import Kyyn.Domain.Failure
import Kyyn.Plumbing.Capability.Failure
import Kyyn.Plumbing.Capability.ProcessExecution
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.ProcessExecution
import System.Directory (getCurrentDirectory)
import System.Environment (getArgs, getExecutablePath, getEnvironment, lookupEnv)
import System.Exit (exitWith, ExitCode(..))
import System.IO (stdin, stdout, stderr, hFlush, hSetBinaryMode)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (signalProcess, nullSignal)
import System.Posix.Types (ProcessID)
import System.Timeout (timeout)
import FileSystemTests (testFileSystem)

main :: IO ()
main = getArgs >>= \args -> case args of
  ["--child", mode] -> child mode
  _ -> do
    completed <- timeout 30000000 (tests >> testFileSystem)
    unless (completed == Just ()) (fail "process tests timed out")
    putStrLn "Process scope tests passed: bytes, diagnostics, nesting, failure and cancellation."

child :: String -> IO ()
child mode = do
  mapM_ (`hSetBinaryMode` True) [stdin, stdout, stderr]
  case mode of
    "echo" -> Bytes.hGetContents stdin >>= Bytes.hPut stdout
    "noisy" -> do
      Bytes.hPut stderr (Bytes.replicate 2097152 120)
      Bytes.hPut stdout "result"
      exitWith (ExitFailure 17)
    "environment" -> do
      value <- lookupEnv "KYYN_PROCESS_TEST"
      cwd <- getCurrentDirectory
      Char8.hPutStr stdout (Char8.pack (show (value, cwd)))
    "hold" -> do
      pid <- getProcessID
      Char8.hPutStrLn stdout (Char8.pack (show pid))
      hFlush stdout
      forever (threadDelay 1000000)
    _ -> fail "unknown child mode"

assert :: String -> Bool -> IO ()
assert label ok = do
  unless ok (fail label)
  putStrLn ("PASS " ++ label)
  hFlush stdout

execute :: Eff '[ProcessExecution, Failure, IOE] a -> IO (Either OperationalFailure a)
execute = runEff . runFailure . runProcessExecutionIO

exchange :: ProcessExecution :> es => ProcessSpec -> Bytes.ByteString -> Eff es (Bytes.ByteString, ProcessExit)
exchange spec bytes = withProcess spec $ do
  writeStdin bytes
  closeStdin
  value <- collectStdout
  result <- awaitExit
  pure (value, result)

childPid :: ProcessPipes :> es => Eff es ProcessID
childPid = readLine Bytes.empty
  where
    readLine acc = do
      part <- readStdout
      case part of
        Nothing -> error "child exited without its PID"
        Just bytes ->
          let joined = acc <> bytes
          in if Bytes.elem 10 joined
             then pure (read (Char8.unpack (Char8.takeWhile (/= '\n') joined)))
             else readLine joined

assertStopped :: ProcessID -> IO ()
assertStopped pid = do
  result <- try @IOException (signalProcess nullSignal pid)
  assert ("child reaped after scope: " ++ show pid) (either isDoesNotExistError (const False) result)

tests :: IO ()
tests = do
  exe <- getExecutablePath
  cwd <- getCurrentDirectory
  env <- getEnvironment
  let spec mode = ProcessSpec exe ["--child", mode] cwd env
      input = Bytes.pack [0..255] <> Bytes.replicate 1048576 42
      rejection = RuntimeUnavailable (ProcessDiagnostic ReadOutput "test rejection")

  bytes <- execute (exchange (spec "echo") input)
  assert "binary payload or EOF round trip" (bytes == Right (input, ProcessExit 0 ""))

  noisy <- execute (exchange (spec "noisy") "")
  assert "stderr must drain independently; nonzero exit is data"
    (noisy == Right ("result", ProcessExit 17 (Bytes.replicate 2097152 120)))

  environmentResult <- execute (exchange ((spec "environment") {environment = [("KYYN_PROCESS_TEST", "selected")]}) "")
  assert "explicit child environment and cwd"
    (environmentResult == Right (Char8.pack (show (Just "selected" :: Maybe String, cwd)), ProcessExit 0 ""))

  missing <- execute (withProcess ((spec "echo") {executable = cwd ++ "/does-not-exist-kyyn"}) (pure ()))
  case missing of
    Left (RuntimeUnavailable ProcessDiagnostic{operation = StartProcess}) -> pure ()
    other -> fail ("missing executable was not an operational failure: " ++ show other)

  invalidCwd <- execute (withProcess ((spec "echo") {workingDirectory = cwd ++ "/does-not-exist-kyyn"}) (pure ()))
  case invalidCwd of
    Left (RuntimeUnavailable ProcessDiagnostic{operation = StartProcess}) -> pure ()
    other -> fail ("missing cwd was not an operational failure: " ++ show other)

  closed <- execute $ withProcess (spec "hold") $ do
    _ <- childPid
    closeStdin
    writeStdin "closed"
  case closed of
    Left (RuntimeUnavailable ProcessDiagnostic{operation = WriteInput}) -> pure ()
    other -> fail ("closed stdin was not a write failure: " ++ show other)

  normal <- execute (withProcess (spec "hold") childPid)
  either (fail . show) assertStopped normal

  observed <- newEmptyMVar
  failed <- execute $ withProcess (spec "hold") $ do
    pid <- childPid
    liftIO (putMVar observed pid)
    raiseFailure rejection >> pure ()
  assert "effect failure preserved" (failed == Left rejection :: Bool)
  takeMVar observed >>= assertStopped

  callback <- try @IOException $ execute $ withProcess (spec "hold") $ do
    pid <- childPid
    liftIO (putMVar observed pid)
    liftIO (throwIO (userError "callback error") :: IO ())
  assert "callback exception is not misclassified as a process failure" (either (const True) (const False) callback)
  takeMVar observed >>= assertStopped

  withAsync (execute $ withProcess (spec "hold") $ do
    pid <- childPid
    liftIO (putMVar observed pid)
    readStdout) $ \worker -> do
      pid <- takeMVar observed
      cancel worker
      outcome <- waitCatch worker
      assert "cancellation must propagate" (either (const True) (const False) outcome)
      assertStopped pid

  nested <- execute $ withProcess (spec "echo") $ do
    writeStdin "outer"
    inner <- exchange (spec "echo") "inner"
    closeStdin
    outer <- collectStdout
    status <- awaitExit
    pure (inner, outer, status)
  assert "nested process scopes target independent pipes"
    (nested == Right (("inner", ProcessExit 0 ""), "outer", ProcessExit 0 ""))

  stateResult <- execute $ runState (0 :: Int) $ withProcess (spec "echo") $ do
    modify @Int (+1)
    closeStdin
    _ <- collectStdout
    awaitExit
  assert "higher-order scope preserves local state"
    (stateResult == Right (ProcessExit 0 "", 1))

  observedInner <- newEmptyMVar
  nestedFailure <- try @SomeException $ execute $ withProcess (spec "hold") $ do
    outer <- childPid
    liftIO (putMVar observed outer)
    withProcess (spec "hold") $ do
      inner <- childPid
      liftIO (putMVar observedInner inner)
      raiseFailure rejection >> pure ()
  case nestedFailure of
    Right (Left err) -> assert "nested failure preserved" (err == rejection)
    _ -> fail "nested failure did not propagate"
  takeMVar observed >>= assertStopped
  takeMVar observedInner >>= assertStopped
