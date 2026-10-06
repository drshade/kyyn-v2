{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Plumbing.Interpreter.FileAcquisition (runFileAcquisitionIO) where

import Control.Exception (IOException, displayException, try)
import Control.Monad (forM, when)
import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.List (sort)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Numeric (showHex)
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
    let source = scopedPath scope path
    refuseLink source
    bytes <- Bytes.readFile source
    contents <- either (ioError . userError . show) pure (Text.decodeUtf8' bytes)
    let fingerprint = concatMap (\byte -> let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits)
          (Bytes.unpack (SHA256.hash (Lazy.toStrict (Builder.toLazyByteString
            (framed (Text.encodeUtf8 (Text.pack source)) <> framed bytes)))))
    pure (CapturedText contents (EvidenceFingerprint (Text.pack fingerprint)))
  where
    framed bytes = Builder.word64BE (fromIntegral (Bytes.length bytes)) <> Builder.byteString bytes

native :: IOE :> es => IO a -> Eff es (Either String a)
native action = liftIO $ either (Left . displayException @IOException) Right <$> try action

enumerate :: FilePath -> Bool -> FilePath -> IO [FilePath]
enumerate base recursive prefix = do
  let directory = if null prefix then base else base </> prefix
  refuseLink directory
  names <- sort <$> listDirectory directory
  concat <$> forM names (\name -> do
    let relative = if null prefix then name else prefix </> name
        absolute = base </> relative
    refuseLink absolute
    child <- doesDirectoryExist absolute
    if child then if recursive then enumerate base recursive relative else pure []
      else do
        file <- doesFileExist absolute
        if file then pure [relative] else ioError (userError (absolute ++ ": not a regular file")))

refuseLink :: FilePath -> IO ()
refuseLink path = do
  linked <- pathIsSymbolicLink path
  when linked (ioError (userError (path ++ ": symbolic links are not supported")))
