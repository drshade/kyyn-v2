{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO) where

import Control.Exception (IOException, displayException, try)
import Control.Monad (forM)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as Bytes
import Data.List (sort, isPrefixOf)
import Data.Word (Word64)
import Numeric (showHex)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift)
import qualified Effectful.Exception as Exception
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.Path
import Kyyn.Domain.FileTree (FileTree, fileTree)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Plumbing.Capability.Failure
import Kyyn.Plumbing.Capability.FileSystem
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive, pathIsSymbolicLink, doesDirectoryExist, doesFileExist, renameFile)
import qualified System.Directory as Directory
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose, hSetBinaryMode)
import System.IO.Temp (createTempDirectory, withTempFile)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Random (randomIO)

runFileSystemIO
  :: (IOE :> es, Failure :> es)
  => DirectoryScope -> Eff (FileSystem : es) a -> Eff es a
runFileSystemIO parent = interpret $ \env -> \case
  WithTemporaryScope action -> localSeqUnlift env $ \unlift ->
    fmap fst $ Exception.generalBracket
      (native Failure.CreateTemporaryScope (scopePath parent) $ createTempDirectory (scopePath parent) "kyyn-")
      (\path exitCase -> case exitCase of
        Exception.ExitCaseSuccess _ -> native Failure.RemoveTemporaryScope path (removeDirectoryRecursive path)
        _ -> liftIO (removeDirectoryRecursive path) `Exception.catch` \(_ :: IOException) -> pure ())
      (\path -> case directoryScope path of
        Right scope -> unlift (action scope)
        Left message -> raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.CreateTemporaryScope path message)))
  ReadBytes scope path -> native Failure.ReadFile (scopedPath scope path) $ Bytes.readFile (scopedPath scope path)
  ReadOptionalBytes scope path -> native Failure.ReadFile (scopedPath scope path) $ do
    result <- try (Bytes.readFile (scopedPath scope path))
    case result of
      Right bytes -> pure (Just bytes)
      Left err | isDoesNotExistError err -> pure Nothing
               | otherwise -> ioError err
  WriteBytes scope path bytes -> native Failure.WriteFile (scopedPath scope path) $ do
    createDirectoryIfMissing True (takeDirectory (scopedPath scope path))
    Bytes.writeFile (scopedPath scope path) bytes
  ReplaceBytes scope path bytes -> native Failure.ReplaceFile (scopedPath scope path) $ do
    let target = scopedPath scope path
        parentDirectory = takeDirectory target
    createDirectoryIfMissing True parentDirectory
    withTempFile parentDirectory ".kyyn-replace-" $ \temporary handle -> do
      hSetBinaryMode handle True
      Bytes.hPut handle bytes
      hClose handle
      renameFile temporary target
  ReadTree scope -> native Failure.ReadDirectoryTree (scopePath scope) $ do
    captured <- captureTree (scopePath scope) []
    either (ioError . userError . show) pure captured
  ReadSourceTree scope excluded -> native Failure.ReadDirectoryTree (scopePath scope)
    (captureTree (scopePath scope) excluded)
  ListDirectory scope -> native Failure.ListDirectory (scopePath scope) $ do
    result <- try (Directory.listDirectory (scopePath scope))
    case result of
      Right names -> Just <$> traverse (either (ioError . userError) pure . relativePath) (sort names)
      Left err | isDoesNotExistError err -> pure Nothing
               | otherwise -> ioError err
  CreateUniqueDirectory scope -> native Failure.CreateUniqueDirectory (scopePath scope) (allocateDirectory (scopePath scope))
  CreateDirectory scope -> native Failure.CreateDirectory (scopePath scope) $ do
    created <- try (Directory.createDirectory (scopePath scope))
    case created of
      Right () -> pure True
      Left err | isAlreadyExistsError err -> pure False
               | otherwise -> ioError err
  EntryExists scope path -> native Failure.InspectEntry (scopedPath scope path) $ do
    result <- try (pathIsSymbolicLink (scopedPath scope path))
    case result of
      Right _ -> pure True
      Left err | isDoesNotExistError err -> pure False
               | otherwise -> ioError err
  EnsureDirectory scope -> native Failure.EnsureDirectory (scopePath scope) (createDirectoryIfMissing True (scopePath scope))

allocateDirectory :: FilePath -> IO RelativePath
allocateDirectory parent = createDirectoryIfMissing True parent >> allocate
  where
    allocate = do
      number <- randomIO :: IO Word64
      let name = showHex number ""
      created <- try (Directory.createDirectory (parent </> name))
      case created of
        Right () -> either (ioError . userError) pure (relativePath name)
        Left err | isAlreadyExistsError err -> allocate
                 | otherwise -> ioError err

captureTree :: FilePath -> [RelativePath] -> IO (Either [Diagnostic] FileTree)
captureTree base excluded = runExceptT $ do
  linked <- liftIO (pathIsSymbolicLink base)
  if linked then unsupported "." else pure ()
  entries <- walk ""
  either (throwE . pure . errorDiagnostic "filesystem.unsupported-entry") pure (fileTree entries)
  where
    unsupported path = throwE [errorDiagnostic "filesystem.unsupported-entry" ("Expected a regular file or directory: " ++ path)]
    omitted path = any (\p -> let name = relativeName p in path == name || (name ++ "/") `isPrefixOf` path) excluded
    walk prefix = do
      names <- liftIO (sort <$> Directory.listDirectory (base </> prefix))
      fmap concat $ forM names $ \name -> do
        let relative = if null prefix then name else prefix ++ "/" ++ name
            absolute = base </> relative
        if omitted relative then pure [] else do
          linked <- liftIO (pathIsSymbolicLink absolute)
          if linked then unsupported relative else pure ()
          directory <- liftIO (doesDirectoryExist absolute)
          if directory then walk relative else do
            regular <- liftIO (doesFileExist absolute)
            if regular then pure () else unsupported relative
            path <- either (throwE . pure . errorDiagnostic "filesystem.unsupported-entry") pure (relativePath relative)
            contents <- liftIO (Bytes.readFile absolute)
            pure [(path,contents)]

native :: (IOE :> es, Failure :> es) => Failure.StorageOperation -> FilePath -> IO a -> Eff es a
native operation path action = liftIO action `Exception.catch` \(err :: IOException) ->
  raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic operation path (displayException err)))
