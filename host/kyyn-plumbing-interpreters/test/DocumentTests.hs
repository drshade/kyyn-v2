{-# LANGUAGE DataKinds, OverloadedStrings #-}
module Main (main) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (async, cancel, concurrently)
import Control.Monad (replicateM_, unless)
import qualified Data.ByteString.Char8 as Bytes
import Data.Either (isLeft)
import Effectful (Eff, IOE, runEff, liftIO)
import Kyyn.Domain.Path (DirectoryScope, directoryScope)
import Kyyn.Plumbing.Capability.DocumentPersistence
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import System.Directory (listDirectory, createDirectory, doesDirectoryExist)
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
  assert "lock didn't create directory" exists
  execute scope (replaceCurrent "0")
  let increment = execute scope $ do
        bytes <- readCurrent
        let number = maybe (error "document disappeared") (read . Bytes.unpack) bytes :: Int
        replaceCurrent (Bytes.pack (show (number + 1)))
  _ <- concurrently (replicateM_ 20 increment) (replicateM_ 20 increment)
  total <- execute scope readCurrent
  assert "lock failed to serialize whole read/modify/replace" (total == Just "40")
  execute scope (archiveCurrent "old" >> archiveCurrent "older")
  archives <- listDirectory (path </> "archives")
  assert "archives collided" (length archives == 2)
  execute scope clearArchives
  remaining <- listDirectory (path </> "archives")
  assert "archive clearing failed" (null remaining)
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
  execute scope (clearCurrent >> clearCurrent)
  cleared <- execute scope readCurrent
  assert "clear didn't remove document" (cleared == Nothing)
  createDirectory (path </> "state.dhall")
  refused <- runEff (runFailure (runDocumentPersistenceIO (withLockedDocument scope (replaceCurrent "cannot replace directory"))))
  assert "replacement failure swallowed" (isLeft refused)
  entries <- listDirectory path
  assert "failed replacement left temporary file" (all (not . Bytes.isPrefixOf ".pending-" . Bytes.pack) entries)
  unreadable <- runEff (runFailure (runDocumentPersistenceIO (withLockedDocument scope readCurrent)))
  assert "directory read reported as absent" (isLeft unreadable)
  putStrLn "Document persistence: scoped locking, atomic replacement, archives, failures and cancellation passed."
