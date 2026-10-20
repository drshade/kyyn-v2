{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Meetings (fetch) where

import Control.Monad (forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (groupBy, sortOn, nub)
import Kyyn.Plugin
import Kyyn.Plugin.Host
import MicrosoftGraph.Meetings.Types
import MicrosoftGraph.Meetings.Api (Pending(..))
import qualified MicrosoftGraph.Meetings.Api as Api
import MicrosoftGraph.Meetings.Fingerprint (artifactId, canonicalArtifact)
import MicrosoftGraph.Timestamp (timestamp, daysBefore)
import qualified MicrosoftGraph.Auth as Auth

fetch :: MeetingsConfig -> Maybe MeetingsFetch -> FetchContext MeetingsPosition -> EvidenceSnapshot MeetingArtifact
  -> Acquisition MeetingArtifact (Either FetchError (FetchResult MeetingArtifact MeetingsPosition))
fetch config@(MeetingsConfig auth _ retention) options (FetchContext started previous) snapshot =
  fmap (either (Left . FetchError) Right) $ runExceptT $ do
    now <- either throwE pure (timestamp started)
    since <- either throwE pure (case options of
      Just (MeetingsFetch (Just value)) -> Right value
      _ -> case previous of
        Nothing -> daysBefore 30 started
        Just (MeetingsPosition lastFetch _) -> daysBefore 1 lastFetch)
    lower <- either throwE pure (timestamp since)
    if lower >= now then throwE "since must precede acquisition start" else pure ()
    if retention < 0 then throwE "retentionDays must be nonnegative" else pure ()
    token <- ExceptT (Auth.accessToken auth)
    urls <- ExceptT (Api.discover token config since started)
    rounds <- mapM (ExceptT . Api.artifacts token (Api.userBase config)) (nub urls)
    let pending = concatMap fst rounds
    let key (Pending kind item _ _ (MeetingRef meetingId _ _ _)) = artifactId kind meetingId item
        candidates = [first | first:_ <- groupBy (\a b -> key a == key b) (sortOn key pending)]
        cutoff = now - fromInteger (retention * 86400)
    captures <- forM candidates $ \item -> do
      prior <- ExceptT (fmap fetchResult (readEvidence snapshot (EvidenceId (key item))))
      case prior of
        Just _ -> pure ([],[])
        Nothing -> do
          (value,denied) <- ExceptT (Api.capture token (Api.userBase config) item)
          pure (maybe [] (\v -> [(key item,v)]) value,denied)
    let fresh = concatMap fst captures
        denied = concatMap snd rounds ++ concatMap snd captures
    digests <- ExceptT (Right <$> digestText (map (canonicalArtifact . snd) fresh))
    if length digests /= length fresh then throwE "Host returned the wrong number of content digests" else pure ()
    additions <- forM (zip fresh digests) $ \((key,value),digest) -> do
      at <- either throwE pure (timestamp (endTime value))
      let MeetingRef _ url _ _ = meetingRef value
      pure (NewEvidence (EvidenceId key) (Evidence (EvidenceFingerprint digest) [url]
        (if at < cutoff then Truncated else Available value)))
    prior <- ExceptT (fmap fetchResult (listEvidenceIds snapshot))
    truncated <- fmap concat $ forM prior $ \key -> do
      old <- ExceptT (fmap fetchResult (readEvidence snapshot key))
      case old of
        Just (Evidence fingerprint _ (Available value)) -> do
          at <- either throwE pure (timestamp (endTime value))
          pure [SetEvidencePayload key fingerprint Truncated | at < cutoff]
        _ -> pure []
    pure (FetchResult (additions ++ truncated) (MeetingsPosition started denied))
  where
    fetchResult = either (\(FetchError message) -> Left message) Right
    endTime (Transcript _ _ end _) = end
    endTime (Attendance _ _ end _) = end
    meetingRef (Transcript meeting _ _ _) = meeting
    meetingRef (Attendance meeting _ _ _) = meeting
