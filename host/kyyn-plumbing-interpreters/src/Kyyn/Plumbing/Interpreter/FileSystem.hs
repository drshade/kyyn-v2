{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO) where

import Control.Exception (IOException, displayException, try)
import qualified Control.Exception as IO
import Control.Monad (forM, forM_, when, unless)
import qualified Data.ByteString as Bytes
import Data.List (sort)
import Data.Word (Word64)
import Numeric (showHex)
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift)
import qualified Effectful.Exception as Exception
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.Path
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
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
  ReadTree scope -> native Failure.ReadDirectoryTree (scopePath scope) (captureTree (scopePath scope))
  ReplaceTree scope path tree -> native Failure.ReplaceDirectoryTree (scopedPath scope path)
    (replaceDirectoryTree (scopedPath scope path) tree)
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
  DirectoryExists scope -> native Failure.InspectEntry (scopePath scope) (doesDirectoryExist (scopePath scope))
  EnsureDirectory scope -> native Failure.EnsureDirectory (scopePath scope) (createDirectoryIfMissing True (scopePath scope))

-- Stage on the destination filesystem. Keep the old tree if publication or
-- rollback fails; never delete it merely because an exception was raised.
replaceDirectoryTree :: FilePath -> FileTree -> IO ()
replaceDirectoryTree target tree = IO.mask $ \restore -> do
  entry <- try (pathIsSymbolicLink target)
  exists <- case entry of
    Right linked -> do
      directory <- doesDirectoryExist target
      unless (directory && not linked) (ioError (userError "Tree destination must be a directory, not a file or symlink"))
      pure True
    Left err | isDoesNotExistError err -> pure False
             | otherwise -> ioError err
  let parentDirectory = takeDirectory target
  createDirectoryIfMissing True parentDirectory
  staging <- createTempDirectory parentDirectory ".kyyn-replace-"
  let fresh = staging </> "new"
      previous = staging </> "previous"
      cleanup = removeDirectoryRecursive staging
  restore (do
    Directory.createDirectory fresh
    forM_ (files tree) $ \(path, bytes) -> do
      let file = fresh </> relativeName path
      createDirectoryIfMissing True (takeDirectory file)
      Bytes.writeFile file bytes) `IO.onException` cleanup
  when exists (Directory.renameDirectory target previous)
  Directory.renameDirectory fresh target `IO.onException`
    when exists (Directory.renameDirectory previous target)
  cleanup

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

captureTree :: FilePath -> IO FileTree
captureTree base = do
  linked <- pathIsSymbolicLink base
  if linked then ioError (userError "Directory scope must not be a symlink") else pure ()
  entries <- walk ""
  either (ioError . userError) pure (fileTree entries)
  where
    walk prefix = do
      names <- sort <$> Directory.listDirectory (base </> prefix)
      fmap concat $ forM names $ \name -> do
        let relative = if null prefix then name else prefix ++ "/" ++ name
            absolute = base </> relative
        linked <- pathIsSymbolicLink absolute
        if linked then ioError (userError ("Symlinks are unsupported: " ++ relative)) else pure ()
        directory <- doesDirectoryExist absolute
        if directory then walk relative else do
          regular <- doesFileExist absolute
          if regular then pure () else ioError (userError ("Expected a regular file: " ++ relative))
          path <- either (ioError . userError) pure (relativePath relative)
          contents <- Bytes.readFile absolute
          pure [(path,contents)]

native :: (IOE :> es, Failure :> es) => Failure.StorageOperation -> FilePath -> IO a -> Eff es a
native operation path action = liftIO action `Exception.catch` \(err :: IOException) ->
  raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic operation path (displayException err)))
