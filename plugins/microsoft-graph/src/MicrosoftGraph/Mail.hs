{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Mail (fetch) where

import Data.Text (Text)
import qualified Data.Text as Text
import Data.List (sort, sortOn, groupBy)
import Control.Monad (forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Kyyn.Plugin
import Kyyn.Plugin.Host
import MicrosoftGraph.Mail.Types
import qualified MicrosoftGraph.Mail.Api as Api
import MicrosoftGraph.Mail.Fingerprint (canonicalMessage)
import qualified MicrosoftGraph.Auth as Auth
import qualified MicrosoftGraph.Json as Json
import MicrosoftGraph.Timestamp (timestamp, daysBefore)
import Text.JSON.Types (JSValue(..), fromJSObject)

fetch :: MailConfig -> Maybe MailFetch -> FetchContext MailPosition -> EvidenceSnapshot Message
  -> Acquisition Message (Either FetchError (FetchResult Message MailPosition))
fetch (MailConfig auth mailbox folders retentionDays) options (FetchContext started prior) snapshot =
  fmap (either (Left . FetchError) Right) $ runExceptT $ do
    now <- either throwE pure (timestamp started)
    let supplied = case options of Just (MailFetch boundary) -> boundary; Nothing -> Nothing
    case (prior,supplied) of
      (Just _,Just _) -> throwE "since is only an initial backfill boundary; clear evidence before choosing another boundary"
      _ -> pure ()
    since <- either throwE pure (maybe (daysBefore 30 started) Right supplied)
    _ <- either throwE pure (timestamp since)
    token <- ExceptT (Auth.accessToken auth)
    let base = Api.baseUrl mailbox
        positions = case prior of Nothing -> []; Just (MailPosition values) -> [(key,(link,boundary)) | FolderPosition key link boundary <- values]
    resolved <- mapM (ExceptT . Api.folderId token base) folders
    rounds <- forM (unique resolved) $ \folder -> do
      let previous = lookup folder positions
          boundary = maybe since snd previous
          initial = base <> "/mailFolders/" <> Json.escape folder <>
            "/messages/delta?$select=id&$filter=" <> Json.escape ("receivedDateTime ge " <> boundary)
      result <- ExceptT (Api.delta token (maybe initial fst previous))
      (entries,next) <- case result of
        Just values -> pure values
        Nothing -> do
          reset <- ExceptT (Api.delta token initial)
          maybe (throwE "Mail delta reset failed; retry the fetch") pure reset
      keys <- either throwE pure (concat <$> mapM messageId entries)
      pure ([(key,folder) | key <- keys],FolderPosition folder next boundary)
    oldIds <- ExceptT (fmap fetchResult (listEvidenceIds snapshot))
    let candidates = firstByKey (concatMap fst rounds)
        unseen = without (sort [key | EvidenceId key <- oldIds]) (sortOn fst candidates)
        cutoff = now - fromInteger (retentionDays * 86400)
    fresh <- forM unseen $ \(key,folder) -> do
      message <- ExceptT (Api.captureMessage token base folder key)
      pure (key,message)
    fingerprints <- ExceptT (Right <$> digestText [canonicalMessage message | (_,message) <- fresh])
    if length fingerprints /= length fresh then throwE "Host returned the wrong number of content digests" else pure ()
    additions <- forM (zip fresh fingerprints) $ \((key,message),fingerprint) -> do
      let Message { received = received } = message
      at <- either throwE pure (timestamp received)
      pure (NewEvidence (EvidenceId key) (Evidence (EvidenceFingerprint fingerprint)
        [base <> "/messages/" <> Json.escape key] (if at < cutoff then Truncated else Available message)))
    truncated <- forM oldIds $ \key -> do
      old <- ExceptT (fmap fetchResult (readEvidence snapshot key))
      case old of
        Just (Evidence fingerprint _ (Available Message { received = received })) -> do
          at <- either throwE pure (timestamp received)
          pure [SetEvidencePayload key fingerprint Truncated | at < cutoff]
        _ -> pure []
    pure (FetchResult (additions ++ concat truncated) (MailPosition (map snd rounds)))
  where
    fetchResult = either (\(FetchError message) -> Left message) Right

messageId :: JSValue -> Either Text [Text]
messageId (JSObject fields) | Just _ <- lookup "@removed" (fromJSObject fields) = Right []
messageId value = do
  key <- Api.textField "id" value
  if Text.null key then Left "Graph message has an empty ID" else pure [key]

firstByKey :: [(Text,a)] -> [(Text,a)]
firstByKey values = [first | first:_ <- groupBy (\a b -> fst a == fst b) (sortOn fst values)]
unique :: [Text] -> [Text]
unique values = map snd (sortOn fst
  [first | first:_ <- groupBy (\a b -> snd a == snd b) (sortOn snd (zip [0 :: Int ..] values))])

without :: [Text] -> [(Text,a)] -> [(Text,a)]
without _ [] = []
without [] values = values
without old@(key:keys) values@((candidate,value):rest) = case compare key candidate of
  LT -> without keys values
  EQ -> without keys rest
  GT -> (candidate,value) : without old rest
