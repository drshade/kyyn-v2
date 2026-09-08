{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO) where

import Control.Exception (IOException, displayException)
import qualified Data.ByteString as Bytes
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift)
import qualified Effectful.Exception as Exception
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.Path
import Kyyn.Plumbing.Capability.Failure
import Kyyn.Plumbing.Capability.FileSystem
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import System.FilePath (takeDirectory)
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
  ReadBytes scope path -> native Failure.ReadBytes (scopedPath scope path) $ Bytes.readFile (scopedPath scope path)
  WriteBytes scope path bytes -> native Failure.WriteBytes (scopedPath scope path) $ do
    createDirectoryIfMissing True (takeDirectory (scopedPath scope path))
    Bytes.writeFile (scopedPath scope path) bytes

native :: (IOE :> es, Failure :> es) => Failure.StorageOperation -> FilePath -> IO a -> Eff es a
native operation path action = liftIO action `Exception.catch` \(err :: IOException) ->
  raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic operation path (displayException err)))
