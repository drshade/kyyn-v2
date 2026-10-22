{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Meetings (fetch) where

import Control.Monad (forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (groupBy, sortOn, nub)
import Kyyn.Plugin
import Kyyn.Plugin.Host
import MicrosoftGraph.Meetings.Types
import MicrosoftGraph.Meetings.Api (Pending(..), Discovery(..))
import MicrosoftGraph.Types (GraphAuth(..))
import qualified MicrosoftGraph.Meetings.Api as Api
import MicrosoftGraph.Meetings.Fingerprint (artifactId, canonicalArtifact)
import MicrosoftGraph.Timestamp (timestamp, daysBefore)
import qualified MicrosoftGraph.Auth as Auth

fetch :: MeetingsConfig -> Maybe MeetingsFetch -> FetchContext MeetingsPosition -> EvidenceSnapshot MeetingArtifact
  -> Acquisition MeetingArtifact (Either FetchError (FetchResult MeetingArtifact MeetingsPosition))
fetch config@(MeetingsConfig auth retention) options (FetchContext started previous) snapshot =
  fmap (either (Left . FetchError) Right) $ runExceptT $ do
    now <- either throwE pure (timestamp started)
    since <- either throwE pure (case options of
      Just (MeetingsFetch (Just value)) -> Right value
      _ -> case previous of
        Nothing -> daysBefore 30 started
        Just (MeetingsPosition lastFetch _ _ _ _) -> daysBefore 1 lastFetch)
    lower <- either throwE pure (timestamp since)
    if lower >= now then throwE "since must precede acquisition start" else pure ()
    if retention < 0 then throwE "retentionDays must be nonnegative" else pure ()
    token <- ExceptT (Auth.accessToken auth)
    let application = case auth of ClientSecret {} -> True; _ -> False
    bases <- nub <$> ExceptT (Api.targets token auth)
    discoveries <- forM bases $ \base -> do
      found <- ExceptT (Api.discover token base application since started)
      pure (base,found)
    rounds <- fmap concat $ forM discoveries $ \(base,found) -> case found of
      Discovered urls _ -> forM (nub urls) $ \url -> do
        result <- ExceptT (Api.artifacts token base url)
        pure (base,result)
      _ -> pure []
    let pending = [(base,item) | (base,(items,_,_)) <- rounds, item <- items]
        skipped = nub (concat [notes | (_,Discovered _ notes) <- discoveries] ++ concat [notes | (_,(_,_,notes)) <- rounds])
        key (Pending kind item _ _ (MeetingRef meetingId _ _ _)) = artifactId kind meetingId item
        candidates = groupBy (\a b -> key (snd a) == key (snd b)) (sortOn (key . snd) pending)
        cutoff = now - fromInteger (retention * 86400)
        captureOptions [] = pure ([],[])
        captureOptions ((base,item):rest) = do
          (value,denied) <- ExceptT (Api.capture token base item)
          case value of
            Just artifact -> pure ([(key item,artifact)],[(base,url) | url <- denied])
            Nothing -> do
              (fresh,moreDenied) <- captureOptions rest
              pure (fresh,[(base,url) | url <- denied] ++ moreDenied)
    captures <- forM candidates $ \choices -> case choices of
      [] -> pure ([],[])
      (_,item):_ -> do
        prior <- ExceptT (fmap fetchResult (readEvidence snapshot (EvidenceId (key item))))
        case prior of
          Just _ -> pure ([],[])
          Nothing -> captureOptions choices
    let fresh = concatMap fst captures
        denied = [(base,url) | (base,(_,notes,_)) <- rounds, url <- notes] ++ concatMap snd captures
        deniedCount = toInteger (length (nub ([base | (base,DeniedUser) <- discoveries] ++ map fst denied)))
        unavailableCount = toInteger (length [() | (_,UnavailableUser) <- discoveries])
        deniedUrls = if application then [] else nub (map snd denied)
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
    pure (FetchResult (additions ++ truncated) (MeetingsPosition started deniedUrls skipped deniedCount unavailableCount))
  where
    fetchResult = either (\(FetchError message) -> Left message) Right
    endTime (Transcript _ _ end _) = end
    endTime (Attendance _ _ end _) = end
    meetingRef (Transcript meeting _ _ _) = meeting
    meetingRef (Attendance meeting _ _ _) = meeting
