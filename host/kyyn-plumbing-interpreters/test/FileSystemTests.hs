{-# LANGUAGE DataKinds, OverloadedStrings #-}
module FileSystemTests (testFileSystem) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (withAsync, cancel, waitCatch)
import Control.Exception (IOException, try, throwIO)
import Control.Monad (unless, forM_)
import qualified Data.ByteString as Bytes
import Effectful (Eff, IOE, runEff, liftIO)
import Effectful.State.Static.Local (runState, modify)
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.Path
import Kyyn.Plumbing.Capability.Failure
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.FileSystem
import System.Directory (doesDirectoryExist, listDirectory)
import System.IO.Temp (withSystemTempDirectory)

testFileSystem :: IO ()
testFileSystem = withSystemTempDirectory "kyyn-fs-tests" $ \temporary -> do
  parent <- either fail pure (directoryScope temporary)
  forM_ ["", "/absolute", "../outside", "a/../b", "a//b", "a/./b", "a\\b", "a\0b"] $ \path ->
    case relativePath path of
      Left _ -> pure ()
      Right _ -> fail ("accepted invalid relative path: " ++ show path)
  let file = either error id (relativePath "nested/value.bin")
      bytes = Bytes.pack [0..255]
      failure = Failure.RuntimeUnavailable (Failure.ProcessDiagnostic Failure.StartProcess "test failure")
      absent scope = doesDirectoryExist (scopePath scope) >>= \exists -> unless (not exists) (fail "temporary scope survived")
  normal <- execute parent $ FS.withTemporaryScope $ \scope -> do
    FS.writeBytes scope file bytes
    value <- FS.readBytes scope file
    pure (scope, value)
  case normal of
    Right (scope, value) -> unless (value == bytes) (fail "byte round trip") >> absent scope
    Left err -> fail (show err)
  selected <- newEmptyMVar
  failed <- execute parent $ FS.withTemporaryScope $ \scope -> do
    liftIO (putMVar selected scope)
    raiseFailure failure >> pure ()
  unless (failed == Left failure) (fail "typed failure lost")
  takeMVar selected >>= absent
  thrown <- try @IOException $ execute parent $ FS.withTemporaryScope $ \scope -> do
    liftIO (putMVar selected scope)
    liftIO (throwIO (userError "callback") :: IO ())
  case thrown of
    Left _ -> pure ()
    Right _ -> fail "callback exception was swallowed"
  takeMVar selected >>= absent
  withAsync (execute parent $ FS.withTemporaryScope $ \scope -> do
    liftIO (putMVar selected scope)
    liftIO (threadDelay 10000000)) $ \worker -> do
      scope <- takeMVar selected
      cancel worker
      result <- waitCatch worker
      case result of
        Left _ -> pure ()
        Right _ -> fail "cancellation was swallowed"
      absent scope
  missing <- execute parent $ FS.withTemporaryScope $ \scope -> FS.readBytes scope file
  case missing of
    Left (Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.ReadBytes _ _)) -> pure ()
    _ -> fail "missing file must be a storage failure"
  state <- execute parent $ runState (0 :: Int) $ FS.withTemporaryScope $ \_ -> modify @Int (+1)
  unless (state == Right ((), 1)) (fail "local state lost")
  contents <- listDirectory temporary
  unless (null contents) (fail "temporary child scope leaked")
  putStrLn "FileSystem scope tests passed: paths, bytes, failure, cancellation and local effects."

execute :: DirectoryScope -> Eff '[FS.FileSystem, Failure, IOE] a -> IO (Either Failure.OperationalFailure a)
execute parent = runEff . runFailure . runFileSystemIO parent
