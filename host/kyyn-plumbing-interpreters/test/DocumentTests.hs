{-# LANGUAGE DataKinds, OverloadedStrings #-}
module Main (main) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (async, cancel, concurrently, wait)
import Control.Monad (replicateM_, unless)
import qualified Data.ByteString.Char8 as Bytes
import Data.Either (isLeft)
import Effectful (Eff, IOE, runEff, liftIO)
import Kyyn.Domain.Path (DirectoryScope, directoryScope)
import Kyyn.Plumbing.Capability.DocumentPersistence
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import System.Directory (listDirectory, createDirectory, doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

execute :: DirectoryScope -> Eff '[DocumentAccess, DocumentPersistence, Failure, IOE] a -> IO a
execute scope action = runEff (runFailure (runDocumentPersistenceIO (withLockedDocument scope action))) >>= either (fail . show) pure

main :: IO ()
main = withSystemTempDirectory "kyyn-document-" $ \directory -> do
  let path = directory </> "nested/document"
      scope = either error id (directoryScope path)
  empty <- execute scope readCurrent
  assert "missing document wasn't optional" (empty == Nothing)
  exists <- doesDirectoryExist path
  assert "read created the document directory" (not exists)
  execute scope (replaceCurrent "0")
  let increment = execute scope $ do
        bytes <- readCurrent
        let number = maybe (error "document disappeared") (read . Bytes.unpack) bytes :: Int
        replaceCurrent (Bytes.pack (show (number + 1)))
  _ <- concurrently (replicateM_ 20 increment) (replicateM_ 20 increment)
  total <- execute scope readCurrent
  assert "lock failed to serialize whole read/modify/replace" (total == Just "40")
  stamp <- execute scope freshStamp
  let DocumentStamp identity timestamp = stamp
  assert "stamp missing fields" (not (null identity) && not (null timestamp))
  entered <- newEmptyMVar
  blocked <- newEmptyMVar
  worker <- async (execute scope (liftIO (putMVar entered () >> takeMVar blocked)))
  takeMVar entered
  cancel worker
  resumed <- timeout 2000000 (execute scope readCurrent)
  assert "cancelled callback retained lock" (resumed == Just (Just "40"))
  firstClear <- execute scope clearCurrent
  secondClear <- execute scope clearCurrent
  assert "clear did not distinguish existing from missing scope" (firstClear && not secondClear)
  absent <- not <$> doesDirectoryExist path
  assert "clear retained the scoped directory" absent
  lockExists <- doesFileExist (path ++ ".lock")
  assert "clear removed lock identity" lockExists
  cleared <- execute scope readCurrent
  assert "clear didn't remove document" (cleared == Nothing)
  createDirectory path
  createDirectory (path </> "extra")
  Bytes.writeFile (path </> "extra/contents") "discard me"
  execute scope (clearCurrent >> replaceCurrent "replacement")
  replaced <- execute scope readCurrent
  extras <- doesDirectoryExist (path </> "extra")
  assert "clear followed by replacement retained extra files" (not extras && replaced == Just "replacement")
  clearedWhileLocked <- newEmptyMVar
  release <- newEmptyMVar
  holder <- async $ execute scope $ do
    _ <- clearCurrent
    liftIO (putMVar clearedWhileLocked () >> takeMVar release)
    replaceCurrent "after clear"
  takeMVar clearedWhileLocked
  attempted <- newEmptyMVar
  acquired <- newEmptyMVar
  waiter <- async $ do
    putMVar attempted ()
    execute scope $ do
      liftIO (putMVar acquired ())
      readCurrent
  takeMVar attempted
  premature <- timeout 100000 (takeMVar acquired)
  putMVar release ()
  wait holder
  observed <- wait waiter
  assert "clear allowed another callback to acquire a different lock" (premature == Nothing)
  assert "waiting callback did not see post-clear replacement" (observed == Just "after clear")
  _ <- execute scope clearCurrent
  _ <- execute scope readCurrent
  createDirectory path
  createDirectory (path </> "state.dhall")
  refused <- runEff (runFailure (runDocumentPersistenceIO (withLockedDocument scope (replaceCurrent "cannot replace directory"))))
  assert "replacement failure swallowed" (isLeft refused)
  entries <- listDirectory path
  assert "failed replacement left temporary file" (all (not . Bytes.isPrefixOf ".pending-" . Bytes.pack) entries)
  unreadable <- runEff (runFailure (runDocumentPersistenceIO (withLockedDocument scope readCurrent)))
  assert "directory read reported as absent" (isLeft unreadable)
  putStrLn "Document persistence: scoped locking, atomic replacement, clearing, failures and cancellation passed."
