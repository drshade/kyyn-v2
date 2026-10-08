-- Real loopback streaming and filesystem storage, nominal nested contract traversal,
-- non-success response metadata, corruption and reclamation. No guest or provider.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Concurrent.Async (withAsync, wait, cancel)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Aeson (object, (.=))
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Data.Either (isLeft)
import qualified Data.Text as Text
import Effectful (runEff, liftIO)
import Kyyn.Domain.Blob
import Kyyn.Domain.DataType
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..))
import Kyyn.Domain.Path (directoryScope)
import Kyyn.Domain.Plugin (pluginName)
import Kyyn.Plumbing.Capability.BlobStorage
import Kyyn.Plumbing.Interpreter.BlobStorage
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Types.Blob (BlobDownload(..), BlobResponse(..))
import Kyyn.Types.PluginHost (HttpRequest(..))
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as Socket
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)

main :: IO ()
main = withSystemTempDirectory "kyyn-blobs-" $ \directory -> do
  scope <- right (directoryScope directory)
  plugin <- right (pluginName "test")
  let instanceRef = ConnectorInstanceRef plugin "one"
      other = ConnectorInstanceRef plugin "two"
      execute action = runEff (runFailure (runFileSystemIO scope (runBlobStorageIO scope action))) >>= right
      bytes = Bytes.concat (replicate 1024 (Bytes.pack [0..255]))
      download url = execute (storeBlobAt instanceRef (BlobDownload (HttpRequest "GET" url [] "") (Just "file.bin") Nothing))
  BlobResponse 200 _ (Just ref@(BlobRef hash size media _)) <-
    serve (response 200 "Content-Type: application/test\r\n" bytes) download >>= right
  assert "download hash/metadata" (Text.length hash == 64 && size == toInteger (Bytes.length bytes) && media == "application/test")
  captured <- execute (readBlobAt instanceRef ref) >>= right
  assert "binary content changed" (captured == bytes)
  assert "cross-instance blob read" . isLeft =<< execute (readBlobAt other ref)
  BlobResponse 200 _ (Just empty) <- serve (response 200 "" "") download >>= right
  emptyBytes <- execute (readBlobAt instanceRef empty) >>= right
  assert "empty content lost" (Bytes.null emptyBytes)
  _ <- serve (response 200 "" bytes) $ \url -> execute $
    withBlobDownloads instanceRef (discardBlobsAt instanceRef) $
      storeBlobAt instanceRef (BlobDownload (HttpRequest "GET" url [] "") Nothing Nothing)
  _ <- execute (checkBlobsAt instanceRef [ref]) >>= right
  cancelledRef <- serve (response 200 "" "cancelled acquisition") $ \url -> do
    ready <- newEmptyMVar
    block <- newEmptyMVar
    withAsync (execute $ withBlobDownloads instanceRef (discardBlobsAt instanceRef) $ do
      responseValue <- storeBlobAt instanceRef (BlobDownload (HttpRequest "GET" url [] "") Nothing Nothing)
      liftIO (putMVar ready responseValue)
      liftIO (takeMVar block :: IO ())) $ \worker -> do
        capturedResponse <- takeMVar ready >>= right
        cancel worker
        case capturedResponse of
          BlobResponse 200 _ (Just capturedRef) -> pure capturedRef
          _ -> fail "Cancellation fixture did not download"
  assert "cancelled acquisition left unpublished blob" . isLeft =<< execute (blobPathAt instanceRef cancelledRef)
  BlobResponse 429 headers Nothing <- serve (response 429 "Retry-After: 2\r\n" "not evidence") download >>= right
  assert "non-success status headers lost" (lookup "Retry-After" headers == Just "2")
  _ <- serveInspect (\request -> assert "redirect forwarded credentials" (not ("private-token" `Bytes.isInfixOf` request)))
    (response 200 "" "redirected") $ \target ->
      serve (response 302 ("Location: " <> Char8.pack (Text.unpack target) <> "\r\n") "") $ \url ->
        execute (storeBlobAt instanceRef (BlobDownload
          (HttpRequest "GET" url [("Authorization","Bearer private-token")] "") Nothing Nothing)) >>= right
  broken <- serve "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort" download
  assert "incomplete stream published" (isLeft broken)
  _ <- execute (checkBlobsAt instanceRef [ref,empty]) >>= right
  path <- execute (blobPathAt instanceRef ref) >>= right
  Bytes.writeFile path "corrupt"
  assert "corrupt blob was readable" . isLeft =<< execute (readBlobAt instanceRef ref)
  assert "corrupt blob passed publication check" . isLeft =<< execute (checkBlobsAt instanceRef [ref])
  execute (reclaimBlobsAt instanceRef [empty])
  _ <- execute (checkBlobsAt instanceRef [empty]) >>= right
  assert "reclamation retained unreferenced content" . isLeft =<< execute (blobPathAt instanceRef ref)
  let datatype = Algebraic "Example.Payload" [] [Constructor "Example.Payload"
        [(Just "attachments",ListType (OptionalType sdkBlobRefType))]]
      value = object ["attachments" .= [object ["tag" .= ("Some" :: String),"value" .= blobValue empty]]]
  refs <- right (blobReferences datatype value)
  assert "nested nominal reference lost" (refs == [empty])
  let lookalike = case sdkBlobRefType of Algebraic _ args cs -> Algebraic "Example.NotBlob" args cs; _ -> error "SDK shape"
  assert "structural lookalike became a blob" (blobReferences lookalike (blobValue empty) == Right [])
  assert "path traversal hash accepted" (isLeft (validateBlobRef (BlobRef "../state.dhall" 0 "" Nothing)))
  putStrLn "Blob streaming, binary integrity, failure, isolation, nominal discovery and reclamation passed."

serve :: Bytes.ByteString -> (Text.Text -> IO a) -> IO a
serve = serveInspect (const (pure ()))

serveInspect :: (Bytes.ByteString -> IO ()) -> Bytes.ByteString -> (Text.Text -> IO a) -> IO a
serveInspect inspect bytes action = do
  result <- timeout 10000000 $ bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \listener -> do
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127,0,0,1)))
    Socket.listen listener 1
    address <- Socket.getSocketName listener
    port <- case address of Socket.SockAddrInet p _ -> pure (show p); _ -> fail "Expected IPv4"
    let respond = bracket (fst <$> Socket.accept listener) Socket.close $ \connection -> do
          let headers received
                | "\r\n\r\n" `Bytes.isInfixOf` received = inspect received
                | otherwise = Socket.recv connection 4096 >>= \chunk ->
                    if Bytes.null chunk then fail "Incomplete request" else headers (received <> chunk)
          headers Bytes.empty
          Socket.sendAll connection bytes
    withAsync respond $ \worker -> do
      value <- action (Text.pack ("http://127.0.0.1:" ++ port ++ "/blob"))
      wait worker
      pure value
  maybe (fail "Blob loopback timed out") pure result

response :: Int -> Bytes.ByteString -> Bytes.ByteString -> Bytes.ByteString
response status headers body = Char8.pack ("HTTP/1.1 " ++ show status ++ " Fixture\r\n") <> headers <>
  Char8.pack ("Content-Length: " ++ show (Bytes.length body) ++ "\r\nConnection: close\r\n\r\n") <> body

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)
