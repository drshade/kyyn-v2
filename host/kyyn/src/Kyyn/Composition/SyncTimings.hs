{-# LANGUAGE DataKinds, GADTs, LambdaCase, ScopedTypeVariables #-}
module Kyyn.Composition.SyncTimings
  ( SyncTimings, newSyncTimings, withSyncReport
  , observeHttp, observeBlobs, observeWaiting, observeEvidence, observeAcquisition ) where

import Control.Exception (IOException, catch, finally)
import Data.IORef
import Data.Word (Word64)
import qualified Data.Text as Text
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpose, passthrough)
import qualified Effectful.Exception as Exception
import GHC.Clock (getMonotonicTimeNSec)
import Kyyn.MicroHs.Timing (emitTiming)
import qualified Kyyn.Plumbing.Capability.HttpTransport as Http
import qualified Kyyn.Plumbing.Capability.BlobStorage as Blobs
import qualified Kyyn.Plumbing.Capability.PluginInteraction as Interaction
import qualified Kyyn.Porcelain.Capability.EvidenceStore as Evidence
import qualified Kyyn.Porcelain.Capability.EvidenceAcquisition as Acquisition
import Kyyn.Types.Blob (BlobResponse(..), BlobRef(..))
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)

data SyncTimings = SyncTimings (IORef Int) (IORef [(String,(Int,Word64))])

newSyncTimings :: Bool -> IO (Maybe SyncTimings)
newSyncTimings False = pure Nothing
newSyncTimings True = Just <$> (SyncTimings <$> newIORef 0 <*> newIORef [])

withSyncReport :: Maybe SyncTimings -> IO a -> IO a
withSyncReport Nothing action = action
withSyncReport (Just (SyncTimings _ totals)) action = do
  start <- getMonotonicTimeNSec
  action `finally` do
    emitTiming "sync-command" "" start
    values <- readIORef totals
    mapM_ (\(stage,(count,nanos)) ->
      hPutStrLn stderr (printf "[kyyn sync] %s calls=%d elapsed_ms=%.3f" stage count (fromIntegral nanos / 1000000 :: Double))
        `catch` \(_ :: IOException) -> pure ()) (reverse values)

measure :: IOE :> es => Maybe SyncTimings -> String -> String -> (a -> String) -> Eff es a -> Eff es a
measure Nothing _ _ _ action = action
measure (Just (SyncTimings serial totals)) stage detail describe action = do
  number <- liftIO (atomicModifyIORef' serial (\n -> (n+1,n+1)))
  start <- liftIO getMonotonicTimeNSec
  let label = "call=" ++ show number ++ " " ++ detail
      finish resultLabel = liftIO $ do
        end <- getMonotonicTimeNSec
        atomicModifyIORef' totals $ \values ->
          let (count,nanos) = maybe (0,0) id (lookup stage values)
          in ((stage,(count+1,nanos+end-start)):filter ((/=stage) . fst) values,())
        emitTiming ("sync-" ++ stage) (label ++ " " ++ resultLabel) start
  liftIO (emitTiming ("sync-" ++ stage ++ "-start") label start)
  result <- action `Exception.onException` finish "aborted"
  finish (describe result)
  pure result

outcome :: Either a b -> String
outcome = either (const "failed") (const "ok")

observeHttp :: (IOE :> es, Http.HttpTransport :> es) => Maybe SyncTimings -> Eff es a -> Eff es a
observeHttp Nothing = id
observeHttp timings = interpose $ \env operation@(Http.SendHttp (Http.HttpRequest method _ _ _)) ->
  measure timings "http" ("method=" ++ safeMethod method) describe (passthrough env operation)
  where
    safeMethod method | method `elem` ["GET","POST","PUT","PATCH","DELETE","HEAD","OPTIONS"] = Text.unpack method
                      | otherwise = "OTHER"
    -- HttpError constructors are nullary. Revisit this before adding fields:
    -- diagnostics must never serialize provider or transport payloads.
    describe (Left problem) = "transport=" ++ show problem
    describe (Right (Http.HttpResponse status _ _)) = "status=" ++ show status

observeBlobs :: (IOE :> es, Blobs.BlobStorage :> es) => Maybe SyncTimings -> Eff es a -> Eff es a
observeBlobs Nothing = id
observeBlobs timings = interpose $ \env operation -> case operation of
  Blobs.StoreBlobAt _ _ -> measure timings "blob-download" "" describe (passthrough env operation)
  _ -> passthrough env operation
  where
    describe (Left _) = "failed"
    describe (Right (BlobResponse status _ blob)) = "status=" ++ show status ++ " bytes=" ++ show (bytes blob)
    bytes Nothing = 0
    bytes (Just (BlobRef _ size _ _)) = size

observeWaiting :: (IOE :> es, Interaction.Waiting :> es) => Maybe SyncTimings -> Eff es a -> Eff es a
observeWaiting Nothing = id
observeWaiting timings = interpose $ \env operation@(Interaction.WaitSeconds seconds) ->
  measure timings "wait" ("requested_seconds=" ++ show seconds) (const "ok") (passthrough env operation)

observeEvidence :: (IOE :> es, Evidence.EvidenceStore :> es) => Maybe SyncTimings -> Eff es a -> Eff es a
observeEvidence Nothing = id
observeEvidence timings = interpose $ \env operation -> case operation of
  Evidence.BeginFetch {} -> measure timings "evidence-begin" "" outcome (passthrough env operation)
  Evidence.ReadCapturedEvidence {} -> measure timings "evidence-read" "" outcome (passthrough env operation)
  Evidence.PublishFetch _ _ _ _ changes _ ->
    measure timings "evidence-publish" ("changes=" ++ show (length changes)) outcome (passthrough env operation)
  _ -> passthrough env operation

observeAcquisition :: (IOE :> es, Acquisition.EvidenceAcquisition :> es) => Maybe SyncTimings -> Eff es a -> Eff es a
observeAcquisition Nothing = id
observeAcquisition timings = interpose $ \env operation@Acquisition.FetchEvidence {} ->
  measure timings "acquisition" "" outcome (passthrough env operation)
