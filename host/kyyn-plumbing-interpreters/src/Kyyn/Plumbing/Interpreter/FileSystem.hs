{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO) where

import Control.Exception (IOException, displayException)
import Control.Monad (forM)
import qualified Data.ByteString as Bytes
import Data.List (sort)
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift)
import qualified Effectful.Exception as Exception
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.Path
import Kyyn.Domain.FileTree (FileTree, fileTree)
import Kyyn.Plumbing.Capability.Failure
import Kyyn.Plumbing.Capability.FileSystem
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive, listDirectory, pathIsSymbolicLink, doesDirectoryExist, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (createTempDirectory)

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
  WriteBytes scope path bytes -> native Failure.WriteFile (scopedPath scope path) $ do
    createDirectoryIfMissing True (takeDirectory (scopedPath scope path))
    Bytes.writeFile (scopedPath scope path) bytes
  ReadTree scope -> native Failure.ReadDirectoryTree (scopePath scope) (captureTree (scopePath scope))

captureTree :: FilePath -> IO FileTree
captureTree base = do
  linked <- pathIsSymbolicLink base
  if linked then ioError (userError "Directory scope must not be a symlink") else pure ()
  entries <- walk ""
  either (ioError . userError) pure (fileTree entries)
  where
    walk prefix = do
      names <- sort <$> listDirectory (base </> prefix)
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
