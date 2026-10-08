{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO) where

import Control.Exception (IOException, displayException, try)
import qualified Data.ByteString as Bytes
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Word (Word32)
import Numeric (showHex)
import Effectful (Eff, IOE, (:>), liftIO, UnliftStrategy(..))
import Effectful.Dispatch.Dynamic (interpret, localLiftUnlift)
import qualified Effectful.Exception as Exception
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.Path (scopePath, relativeName)
import Kyyn.Plumbing.Capability.DocumentPersistence
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive, renameFile)
import System.FileLock (lockFile, unlockFile, SharedExclusive(..))
import System.FilePath ((</>), takeDirectory)
import System.IO (hClose, hSetBinaryMode)
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withTempFile)
import System.Random (randomIO)

runDocumentPersistenceIO :: (IOE :> es, Failure :> es) => Eff (DocumentPersistence : es) a -> Eff es a
runDocumentPersistenceIO = interpret $ \env (WithLockedDocument scope name action) ->
  localLiftUnlift env SeqUnlift $ \liftLocal unlift -> do
    let directory = scopePath scope
    native Failure.EnsureDirectory directory (createDirectoryIfMissing True (takeDirectory directory))
    Exception.bracket
      (native Failure.InspectEntry directory (lockFile (directory ++ ".lock") Exclusive))
      (native Failure.InspectEntry directory . unlockFile)
      (const (unlift (interpret (\_ operation -> liftLocal (handleDocument directory (relativeName name) operation)) action)))

handleDocument :: (IOE :> es, Failure :> es) => FilePath -> FilePath -> DocumentAccess m a -> Eff es a
handleDocument directory name = \case
  ReadCurrent -> native Failure.ReadFile directory $ do
    result <- try (Bytes.readFile (directory </> name))
    case result of
      Right bytes -> pure (Just bytes)
      Left err | isDoesNotExistError err -> pure Nothing
               | otherwise -> ioError err
  ReplaceCurrent bytes -> native Failure.ReplaceFile directory $ do
    createDirectoryIfMissing True directory
    createDirectoryIfMissing True (takeDirectory (directory </> name))
    withTempFile directory ".pending-" $ \path handle -> do
      hSetBinaryMode handle True
      Bytes.hPut handle bytes
      hClose handle
      renameFile path (directory </> name)
  ClearCurrent -> native Failure.WriteFile directory (removeOptional directory)
  FreshStamp -> native Failure.CreateUniqueDirectory directory $
    DocumentStamp <$> freshIdentity <*> (iso8601Show <$> getCurrentTime)

freshIdentity :: IO String
freshIdentity = do
  value <- randomIO :: IO Word32
  let digits = showHex value ""
  pure (replicate (8 - length digits) '0' ++ digits)

removeOptional :: FilePath -> IO Bool
removeOptional path = do
  result <- try (removeDirectoryRecursive path)
  case result of
    Left err | isDoesNotExistError err -> pure False
             | otherwise -> ioError err
    Right () -> pure True

native :: (IOE :> es, Failure :> es) => Failure.StorageOperation -> FilePath -> IO a -> Eff es a
native operation path action = liftIO action `Exception.catch` \(err :: IOException) ->
  raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic operation path (displayException err)))
