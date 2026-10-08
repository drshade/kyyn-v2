{-# LANGUAGE GADTs, LambdaCase, OverloadedStrings #-}
module Kyyn.Plumbing.Interpreter.BlobStorage (runBlobStorageIO) where

import Control.Exception (IOException, try, catch, mask_)
import Control.Monad (forM_, unless)
import qualified Crypto.Hash.SHA256 as SHA
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import qualified Data.CaseInsensitive as CI
import Data.String (fromString)
import Data.IORef (newIORef, readIORef, modifyIORef')
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift)
import qualified Effectful.Exception as Exception
import Kyyn.Domain.Blob (BlobRef(..), validateBlobRef)
import Kyyn.Domain.Evidence (instancePath)
import Kyyn.Domain.KnowledgeBase (cacheLocation)
import Kyyn.Domain.Path (DirectoryScope, scopePath, relativeName)
import Kyyn.Plumbing.Capability.BlobStorage
import qualified Kyyn.Plumbing.Capability.FileSystem as Files
import Kyyn.Types.Blob (BlobDownload(..), BlobResponse(..))
import Kyyn.Types.Plugin (FetchError(..))
import Kyyn.Types.PluginHost (HttpRequest(..))
import qualified Network.HTTP.Client as Http
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing, renameFile, listDirectory, removeFile, doesFileExist, getFileSize)
import System.FilePath ((</>))
import System.IO (hClose, hSetBinaryMode)
import System.IO.Temp (withTempFile)

runBlobStorageIO :: (IOE :> es, Files.FileSystem :> es)
  => DirectoryScope -> Eff (BlobStorage : es) a -> Eff es a
runBlobStorageIO kb action = do
  manager <- liftIO (Http.newManager tlsManagerSettings { Http.managerRetryableException = const False })
  created <- liftIO (newIORef [])
  interpret (\env -> \case
    WithBlobDownloads instanceRef cleanup operation -> localSeqUnlift env $ \unlift -> do
      before <- liftIO (length <$> readIORef created)
      unlift operation `Exception.finally` (do
        after <- liftIO (readIORef created)
        unlift (cleanup [ref | (owner,ref) <- take (length after - before) after, owner == instanceRef]))
    StoreBlobAt instanceRef download -> do
      Files.ensureIgnoredDirectory kb cacheLocation
      liftIO (safe (downloadBlob manager (directory instanceRef)
        (\ref -> modifyIORef' created ((instanceRef,ref):)) download))
    DiscardBlobsAt instanceRef refs -> liftIO $ forM_ refs $ \ref -> do
      path <- checkedPath (directory instanceRef) ref
      removeFile path `catch` \(_ :: IOException) -> pure ()
    ReadBlobAt instanceRef ref -> liftIO (safe $ do
      path <- checkedPath (directory instanceRef) ref
      bytes <- Bytes.readFile path
      checkBytes ref bytes
      pure bytes)
    CheckBlobsAt instanceRef refs -> liftIO (safe (mapM_ (checkFile (directory instanceRef)) refs))
    ReclaimBlobsAt instanceRef refs -> liftIO $ do
      -- Reclamation is best effort; a later publication can retry abandoned bytes.
      let keep = [Text.unpack hash | BlobRef hash _ _ _ <- refs]
      names <- listDirectory (directory instanceRef) `catch` \(_ :: IOException) -> pure []
      forM_ names $ \name -> unless (name `elem` keep) $
        removeFile (directory instanceRef </> name) `catch` \(_ :: IOException) -> pure ()
    BlobPathAt instanceRef ref -> liftIO (safe (checkFile (directory instanceRef) ref >> checkedPath (directory instanceRef) ref))) action
  where
    directory instanceRef = scopePath kb </> relativeName cacheLocation </> "evidence" </> instancePath instanceRef </> "blobs"

safe :: IO a -> IO (Either FetchError a)
safe action = do
  result <- try @IOException (try @Http.HttpException action)
  pure $ case result of
    Left _ -> Left (FetchError "Blob storage unavailable or content missing/corrupt; fetch the connector again.")
    Right (Left _) -> Left (FetchError "Blob download failed; retry the fetch.")
    Right (Right value) -> Right value

checkedPath :: FilePath -> BlobRef -> IO FilePath
checkedPath directory ref@(BlobRef hash _ _ _) =
  either (ioError . userError) (const (pure (directory </> Text.unpack hash))) (validateBlobRef ref)

checkBytes :: BlobRef -> Bytes.ByteString -> IO ()
checkBytes (BlobRef expected size _ _) bytes =
  unless (toInteger (Bytes.length bytes) == size && hex (SHA.hash bytes) == expected)
    (ioError (userError "Blob content integrity mismatch"))

checkFile :: FilePath -> BlobRef -> IO ()
checkFile directory ref@(BlobRef _ size _ _) = do
  path <- checkedPath directory ref
  actualSize <- getFileSize path
  unless (size == actualSize) (ioError (userError "Blob byte count mismatch"))

digest :: IO Bytes.ByteString -> (Bytes.ByteString -> IO ()) -> IO (Text.Text,Integer)
digest next consume = go SHA.init 0
  where
    go context size = do
      chunk <- next
      if Bytes.null chunk then pure (hex (SHA.finalize context),size) else do
        consume chunk
        let context' = SHA.update context chunk
            size' = size + toInteger (Bytes.length chunk)
        context' `seq` size' `seq` go context' size'

hex :: Bytes.ByteString -> Text.Text
hex = Text.pack . concatMap (\byte -> let value = showHex byte "" in replicate (2 - length value) '0' ++ value) . Bytes.unpack

downloadBlob :: Http.Manager -> FilePath -> (BlobRef -> IO ()) -> BlobDownload -> IO BlobResponse
downloadBlob manager directory remember (BlobDownload (HttpRequest method url headers body) suppliedName suppliedType) = do
  base <- Http.parseRequest (Text.unpack url)
  let request = base
        { Http.method = Text.encodeUtf8 method
        , Http.requestHeaders = [(fromString (Text.unpack name),Text.encodeUtf8 value) | (name,value) <- headers]
        , Http.requestBody = Http.RequestBodyBS (Text.encodeUtf8 body)
        , Http.checkResponse = \_ _ -> pure ()
        , Http.shouldStripHeaderOnRedirect = const True
        , Http.shouldStripHeaderOnRedirectIfOnDifferentHostOnly = False
        }
  Http.withResponse request manager $ \response -> do
    let status = statusCode (Http.responseStatus response)
        fields = [(Text.decodeUtf8 (CI.original name),Text.pack (Char8.unpack value)) | (name,value) <- Http.responseHeaders response]
    if status < 200 || status >= 300 then pure (BlobResponse status fields Nothing) else do
      createDirectoryIfMissing True directory
      withTempFile directory ".download" $ \temporary handle -> do
        hSetBinaryMode handle True
        (hash,size) <- digest (Http.brRead (Http.responseBody response)) (Bytes.hPut handle)
        hClose handle
        let media = maybe (maybe "application/octet-stream" (Text.pack . Char8.unpack)
              (lookup "Content-Type" (Http.responseHeaders response))) id suppliedType
            ref = BlobRef hash size media suppliedName
            destination = directory </> Text.unpack hash
        mask_ $ do
          existed <- doesFileExist destination
          renameFile temporary destination
          unless existed (remember ref)
        pure (BlobResponse status fields (Just ref))
