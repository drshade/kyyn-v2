{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Meetings (fetch) where

import Control.Monad (forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Text (Text)
import Data.List (groupBy, sortOn, nub, group, sort)
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
  -> Acquisition MeetingArtifact (Either FetchError (FetchResult MeetingArtifact MeetingsPosition MeetingsReport))
fetch (MeetingsConfig auth retention) options (FetchContext started previous) snapshot =
  fmap (either (Left . FetchError) Right) $ runExceptT $ do
    now <- either throwE pure (timestamp started)
    since <- either throwE pure (case options of
      Just (MeetingsFetch (Just value)) -> Right value
      _ -> case previous of
        Nothing -> daysBefore 30 started
        Just (MeetingsPosition lastFetch) -> daysBefore 1 lastFetch)
    lower <- either throwE pure (timestamp since)
    if lower >= now then throwE "since must precede acquisition start" else pure ()
    if retention < 0 then throwE "retentionDays must be nonnegative" else pure ()
    token <- ExceptT (Auth.accessToken auth)
    let application = case auth of ClientSecret {} -> True; _ -> False
    bases <- unique <$> ExceptT (Api.targets token auth)
    discoveries <- parallel [fmap (fmap ((,) target)) (Api.discover token context base application since started)
      | target@(context,base) <- bases]
    artifactToken <- ExceptT (Auth.accessToken auth)
    rounds <- parallel [fmap (fmap ((,) target)) (Api.artifacts artifactToken context base url since started)
      | (target@(context,base),Discovered urls _) <- discoveries, url <- nub urls]
    captureToken <- ExceptT (Auth.accessToken auth)
    let pending = [(base,item) | (base,(items,_,_,_)) <- rounds, item <- items]
        skipped = nub (concat [notes | (_,Discovered _ notes) <- discoveries] ++ concat [notes | (_,(_,_,notes,_)) <- rounds])
        key (Pending kind item _ _ (MeetingRef meetingId _ _ _)) = artifactId kind meetingId item
        candidates = groupBy (\a b -> key (snd a) == key (snd b)) (sortOn (key . snd) pending)
        cutoff = now - fromInteger (retention * 86400)
        captureOptions [] = pure ([],[])
        captureOptions (((context,base),item):rest) = do
          (value,denied) <- ExceptT (Api.capture captureToken context base item)
          case value of
            Just artifact -> pure ([(key item,artifact)],denied)
            Nothing -> do
              (fresh,moreDenied) <- captureOptions rest
              pure (fresh,denied ++ moreDenied)
    captures <- parallel [runExceptT $ case choices of
      [] -> pure ([],[])
      (_,item):_ -> do
        prior <- ExceptT (fmap fetchResult (readEvidence snapshot (EvidenceId (key item))))
        case prior of
          Just _ -> pure ([],[])
          Nothing -> captureOptions choices
      | choices <- candidates]
    let fresh = concatMap fst captures
        denied = nub (concat [notes | (_,(_,notes,_,_)) <- rounds] ++ concatMap snd captures ++
          [MeetingIssue context CalendarDiscovery Nothing "Access refused (HTTP 403)"
          | ((context,_),DeniedUser) <- discoveries])
        unavailable = [MeetingIssue context CalendarDiscovery Nothing code
          | ((context,_),UnavailableUser code) <- discoveries]
        limits = nub (concat [notes | (_,(_,_,_,notes)) <- rounds])
        scope = if application then EnabledMemberMailboxes (unique [key | (DirectoryUser key,_) <- bases]) else DelegatedMailbox
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
    pure (FetchResult (additions ++ truncated) (MeetingsPosition started)
      (MeetingsReport since started scope denied unavailable skipped limits))
  where
    fetchResult = either (\(FetchError message) -> Left message) Right
    endTime (Transcript _ _ end _) = end
    endTime (Attendance _ _ end _) = end
    meetingRef (Transcript meeting _ _ _) = meeting
    meetingRef (Attendance meeting _ _ _) = meeting

unique :: Ord a => [a] -> [a]
unique values = [first | first:_ <- group (sort values)]

parallel :: [Acquisition payload (Either Text a)] -> ExceptT Text (Acquisition payload) [a]
parallel = ExceptT . concurrentlyE
