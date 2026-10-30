-- Recording interpreters verify sync telemetry, payload omission, no-op disabled
-- mode, response preservation and exception/cancellation propagation. No network.
{-# LANGUAGE DataKinds, GADTs, OverloadedStrings, TypeApplications #-}
module Main (main) where
import Control.Exception (AsyncException(..), bracket, throwIO, try)
import Control.Monad (unless, forM_)
import qualified Data.ByteString.Char8 as Bytes
import Data.List (isInfixOf)
import Effectful (runEff, liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import Kyyn.Composition.SyncTimings
import qualified Kyyn.Plumbing.Capability.HttpTransport as Http
import qualified Kyyn.Plumbing.Capability.BlobStorage as Blobs
import qualified Kyyn.Plumbing.Capability.PluginInteraction as Interaction
import Kyyn.Plumbing.Interpreter.ConcurrentExecution (ConcurrentEvent(..))
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..))
import Kyyn.Domain.Plugin (pluginName)
import Kyyn.Types.Blob (BlobDownload(..), BlobResponse(..), BlobRef(..))
import System.IO (stderr, hFlush, hSeek, SeekMode(..), hClose)
import System.IO.Temp (withSystemTempFile)

main :: IO ()
main = do
  plugin <- either fail pure (pluginName "test")
  let ref = ConnectorInstanceRef plugin "private-instance"
      request = Http.HttpRequest "GET" "https://private-url.test/secret" [("Authorization","secret-header")] "secret-body"
      expected = Right (Http.HttpResponse 429 [("Retry-After","secret-response-header")] "secret-response-body")
      exercise enabled = do
        timing <- newSyncTimings enabled
        capture $ withSyncReport timing $ runEff
          . interpret (\_ (Interaction.WaitSeconds _) -> pure ()) . observeWaiting timing
          . interpret (\_ (Http.SendHttp _) -> pure expected) . observeHttp timing
          . interpret (\_ operation -> case operation of
              Blobs.StoreBlobAt _ _ -> pure (Right (BlobResponse 200 [("X","private-blob-header")]
                (Just (BlobRef "private-digest" 123 "private-media" (Just "private-filename")))))
              _ -> error "Unexpected blob operation") . observeBlobs timing $ do
            liftIO (observeConcurrent timing (RoundStarted 4 3) >> observeConcurrent timing WorkerStarted)
            response <- Http.sendHttp request
            Interaction.waitSeconds 2
            blob <- Blobs.storeBlobAt ref (BlobDownload request (Just "private-name") Nothing)
            liftIO (observeConcurrent timing WorkerFinished >> observeConcurrent timing RoundFinished)
            pure (response,blob)
  (off,quiet) <- exercise False
  (on,logText) <- exercise True
  assert "timing changed responses" (off == on && fst on == expected)
  assert "disabled instrumentation emitted output" (null quiet)
  forM_ ["sync-http-start", "method=GET status=429", "requested_seconds=2 ok", "status=200 bytes=123",
    "[kyyn sync] http calls=1", "[kyyn sync] wait calls=1", "[kyyn sync] blob-download calls=1", "sync-command", "round width=4 requests=3 remote=2 waiting=1 local=0", "peak_in_flight=1", "status=429 calls=1"] $ \expectedText ->
      assert ("missing telemetry " ++ expectedText) (expectedText `isInfixOf` logText)
  forM_ ["private-", "secret-", "Authorization", "https://"] $ \secret ->
    assert "request/response content leaked" (not (secret `isInfixOf` logText))
  timing <- newSyncTimings True
  (failure,failedLog) <- capture $ withSyncReport timing $ runEff
    . interpret (\_ (Http.SendHttp _) -> pure (Left Http.HttpConnectionFailed)) . observeHttp timing $ Http.sendHttp request
  assert "transport failure changed" (failure == Left Http.HttpConnectionFailed)
  assert "transport outcome absent" ("transport=HttpConnectionFailed" `isInfixOf` failedLog)
  cancelledTiming <- newSyncTimings True
  (cancelled,cancelledLog) <- capture $ try @AsyncException $ withSyncReport cancelledTiming $ runEff
    . interpret (\_ (Http.SendHttp _) -> liftIO (throwIO ThreadKilled)) . observeHttp cancelledTiming $ Http.sendHttp request
  assert "cancellation swallowed" (case cancelled of Left ThreadKilled -> True; _ -> False)
  assert "aborted operation missing" ("aborted" `isInfixOf` cancelledLog && "http calls=1" `isInfixOf` cancelledLog)
  putStrLn "Sync timings preserve results/cancellation and omit request, response and blob contents."

capture :: IO a -> IO (a,String)
capture action = withSystemTempFile "kyyn-sync-timings" $ \_ handle -> do
  result <- bracket (hDuplicate stderr) (\saved -> hFlush stderr >> hDuplicateTo saved stderr >> hClose saved) $ \_ -> do
    hDuplicateTo handle stderr
    action
  hFlush handle
  hSeek handle AbsoluteSeek 0
  output <- Bytes.hGetContents handle
  pure (result,Bytes.unpack output)

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)
