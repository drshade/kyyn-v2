{-# LANGUAGE DataKinds, GADTs, LambdaCase, ScopedTypeVariables, TypeApplications #-}
module Kyyn.Plumbing.Interpreter.AppendJournal (runAppendJournalIO) where

import Control.Concurrent.MVar
import Control.Exception (IOException, SomeException, SomeAsyncException, displayException, fromException, try, throwIO, mask_)
import qualified Control.Exception as IO
import Control.Monad (forM, unless, when, void)
import qualified Data.ByteString as Bytes
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import qualified Data.Text as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Numeric.Natural (Natural)
import Effectful (Eff, IOE, (:>), liftIO, UnliftStrategy(..))
import Effectful.Dispatch.Dynamic (interpret, localLiftUnlift)
import qualified Effectful.Exception as Exception
import Kyyn.Domain.Path (scopePath, scopedPath, relativePath)
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Plumbing.Capability.AppendJournal
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import System.Directory
import System.FilePath ((</>), takeFileName)
import System.FileLock
import System.IO (hClose)
import qualified System.Posix.IO as Posix
import System.Posix.Types (Fd)
import Foreign.Ptr (castPtr, plusPtr)
import System.IO.Temp (createTempDirectory, withTempFile)

data Writer = Writer Word64 (MVar WriterState)
data WriterState = WriterState Fd Bool Bool -- terminal, broken

runAppendJournalIO :: (IOE :> es, Failure :> es) => Eff (AppendJournal : es) a -> Eff es a
runAppendJournalIO action = do
  writers <- liftIO (newIORef Map.empty)
  interpret (\env -> \case
    WithJournal directory header cleanup use -> localLiftUnlift env SeqUnlift $ \_ unlift -> do
      let base = scopePath directory
      Exception.bracket (native Failure.WriteFile base (openJournal base header))
        (\(JournalStamp name _,writer,lock) -> do
          let path = scopedPath directory name
          liftIO (atomicModifyIORef' writers (\m -> (Map.delete path m,())))
          -- Close failures are reported; an interrupted append is never retried.
          native Failure.WriteFile path (closeWriter writer `IO.finally` unlockFile lock))
        (\(stamp@(JournalStamp name _),writer,_) -> do
          liftIO (atomicModifyIORef' writers (\m -> (Map.insert (scopedPath directory name) writer m,())))
          unlift (use stamp) `Exception.catch` \(problem :: SomeException) -> do
            open <- liftIO (isOpen writer)
            when open $ void $ Exception.try @SomeException $ unlift $ cleanup stamp $
              case fromException problem :: Maybe SomeAsyncException of
                Just _ -> JournalCancelled
                Nothing -> JournalException (displayException problem)
            Exception.throwIO problem)
    AppendJournal directory name terminal encode -> do
      let path = scopedPath directory name
      current <- liftIO (Map.lookup path <$> readIORef writers)
      case current of
        Nothing -> failAt Failure.WriteFile path "Journal writer is outside its lifetime"
        Just writer -> native Failure.WriteFile (path </> "events.jsonl") (append writer terminal encode)
    ReadJournal directory name -> do
      let path = scopedPath directory name
      native Failure.ReadFile path $ do
        header <- Bytes.readFile (path </> "header.json")
        -- Probe before reading: observing a stopped writer must include all of its
        -- flushed events. If it stops during the read, the next poll settles it.
        acquired <- tryLockFile (path ++ ".lock") Shared
        let readSnapshot = do
              bytes <- Bytes.readFile (path </> "events.jsonl")
              let (records,partial) = case reverse (Bytes.split 10 bytes) of
                    [] -> ([],False)
                    tailBytes:rest -> (reverse rest,not (Bytes.null tailBytes))
              pure (JournalSnapshot header records (case acquired of Nothing -> True; _ -> False) partial)
        readSnapshot `IO.finally` mapM_ unlockFile acquired
    ListJournals directory -> native Failure.InspectEntry (scopePath directory) $ do
      let base = scopePath directory
      exists <- doesDirectoryExist base
      if not exists then pure [] else do
        names <- listDirectory base
        fmap catMaybes $ forM names $ \name -> do
          published <- doesFileExist (base </> name </> "header.json")
          if published then Just <$> either (ioError . userError) pure (relativePath name) else pure Nothing
    ClearJournal directory name -> do
      let path = scopedPath directory name
      native Failure.WriteFile path $ do
        acquired <- tryLockFile (path ++ ".lock") Exclusive
        case acquired of
          Nothing -> ioError (userError "Recording is busy (a writer or reader holds its lock); cannot clear it")
          Just lock -> (do
            exists <- doesFileExist (path </> "header.json")
            unless exists (ioError (userError "Recording does not exist"))
            -- Keep the lock inode: unlinking it could let a new writer bypass
            -- a process that already opened the previous lock file.
            removeDirectoryRecursive path) `IO.finally` unlockFile lock
    ) action

failAt :: Failure :> es => Failure.StorageOperation -> FilePath -> String -> Eff es a
failAt operation path message = raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic operation path message))
native :: (IOE :> es, Failure :> es) => Failure.StorageOperation -> FilePath -> IO a -> Eff es a
native operation path action = liftIO (try @IOException action) >>= either (failAt operation path . displayException) pure

openJournal :: FilePath -> (JournalStamp -> Either String Bytes.ByteString) -> IO (JournalStamp,Writer,FileLock)
openJournal directory header = IO.mask $ \restore -> do
  createDirectoryIfMissing True directory
  path <- createTempDirectory directory "run"
  name <- either (ioError . userError) pure (relativePath (takeFileName path))
  lock <- lockFile (path ++ ".lock") Exclusive `IO.onException` removeDirectoryRecursive path
  (do
    started <- Text.pack . iso8601Show <$> getCurrentTime
    clock <- getMonotonicTimeNSec
    let stamp = JournalStamp name started
    handle <- Posix.openFd (path </> "events.jsonl") Posix.WriteOnly
      (Posix.defaultFileFlags { Posix.append = True, Posix.creat = Just 0o600, Posix.cloexec = True })
    (do
      restore $ withTempFile path ".header-" $ \temporary output -> do
        contents <- either (ioError . userError) pure (header stamp)
        Bytes.hPut output contents
        hClose output
        renameFile temporary (path </> "header.json")
      mutex <- newMVar (WriterState handle False False)
      pure (stamp,Writer clock mutex,lock)) `IO.onException` Posix.closeFd handle
    ) `IO.onException` (unlockFile lock >> removeDirectoryRecursive path)
closeWriter :: Writer -> IO ()
closeWriter (Writer _ mutex) = withMVar mutex (\(WriterState handle _ _) -> Posix.closeFd handle)
isOpen :: Writer -> IO Bool
isOpen (Writer _ mutex) = withMVar mutex (\(WriterState _ terminal broken) -> pure (not terminal && not broken))

append :: Writer -> Bool -> (Natural -> Bytes.ByteString) -> IO Natural
append (Writer started mutex) terminal encode = mask_ $ do
  outcome <- modifyMVar mutex $ \(WriterState handle closed broken) -> do
    when (closed || broken) (ioError (userError "Recording is closed or its writer failed"))
    result <- try @SomeException $ do
      now <- getMonotonicTimeNSec
      let elapsed = fromIntegral (now - started)
          bytes = encode elapsed
      when (Bytes.elem 10 bytes) (ioError (userError "Journal record contains a newline"))
      -- Native descriptor writes have no Haskell Handle buffer or in-process
      -- reader lock. Completion makes the full record visible before acknowledgement.
      Bytes.useAsCStringLen (bytes <> Bytes.singleton 10) $ \(pointer, count) -> do
        let writeAll offset
              | offset == count = pure ()
              | otherwise = do
                  written <- Posix.fdWriteBuf handle (castPtr pointer `plusPtr` offset) (fromIntegral (count-offset))
                  when (written == 0) (ioError (userError "Journal write made no progress"))
                  writeAll (offset + fromIntegral written)
        writeAll 0
      pure elapsed
    pure $ case result of
      Left problem -> (WriterState handle closed True,Left problem)
      Right elapsed -> (WriterState handle terminal False,Right elapsed)
  either throwIO pure outcome
