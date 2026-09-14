{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Plumbing.Interpreter.FileAcquisition (runFileAcquisitionIO) where

import Control.Exception (IOException, displayException, try)
import Control.Monad (forM, when)
import qualified Data.ByteString as Bytes
import Data.List (sort)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Path
import Kyyn.Plumbing.Capability.FileAcquisition
import System.Directory (listDirectory, doesDirectoryExist, doesFileExist, pathIsSymbolicLink)
import System.FilePath ((</>))

runFileAcquisitionIO :: IOE :> es => Eff (FileAcquisition : es) a -> Eff es a
runFileAcquisitionIO = interpret $ \_ -> \case
  ListSourceFiles scope recursive -> native $ do
    names <- enumerate (scopePath scope) recursive ""
    traverse (either (ioError . userError) pure . relativePath) names
  ReadSourceText scope path -> native $ do
    bytes <- Bytes.readFile (scopedPath scope path)
    either (ioError . userError . show) (pure . Text.unpack) (Text.decodeUtf8' bytes)

native :: IOE :> es => IO a -> Eff es (Either String a)
native action = liftIO $ either (Left . displayException @IOException) Right <$> try action

enumerate :: FilePath -> Bool -> FilePath -> IO [FilePath]
enumerate base recursive prefix = do
  let directory = if null prefix then base else base </> prefix
  linked <- pathIsSymbolicLink directory
  when linked (ioError (userError (directory ++ ": symbolic links are not supported")))
  names <- sort <$> listDirectory directory
  concat <$> forM names (\name -> do
    let relative = if null prefix then name else prefix </> name
        absolute = base </> relative
    link <- pathIsSymbolicLink absolute
    when link (ioError (userError (absolute ++ ": symbolic links are not supported")))
    child <- doesDirectoryExist absolute
    if child then if recursive then enumerate base recursive relative else pure []
      else do
        file <- doesFileExist absolute
        if file then pure [relative] else ioError (userError (absolute ++ ": not a regular file")))
