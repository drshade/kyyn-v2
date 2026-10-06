{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Calendar (fetch) where

import qualified Data.Text as Text
import Data.Text (Text)
import Control.Monad (forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (group, sort, sortOn)
import Kyyn.Plugin
import Kyyn.Plugin.Host
import MicrosoftGraph.Types
import MicrosoftGraph.Config (scope)
import MicrosoftGraph.Timestamp (timestamp)
import qualified MicrosoftGraph.Auth as Auth
import qualified MicrosoftGraph.Http as Http
import qualified MicrosoftGraph.Json as Json
import Text.JSON.Types (JSValue(..), fromJSObject)

fetch :: CalendarConfig -> Maybe CalendarFetch -> EvidenceSnapshot Event -> Acquisition Event (Either FetchError [EvidenceChange Event])
fetch config@(CalendarConfig auth mailbox calendar _) options snapshot = fmap (either (Left . FetchError) Right) $ runExceptT $ do
  bounds <- either throwE pure (traverse checkedBounds options)
  token <- ExceptT (Auth.accessToken auth (scope config))
  let base = "https://graph.microsoft.com/v1.0/users/" <> Json.escape mailbox <>
        maybe "/calendar" (("/calendars/" <>) . Json.escape) calendar <> "/events"
      select = "?$select=id,changeKey,subject,bodyPreview,start,end,organizer,attendees,location,isAllDay,isCancelled,type,iCalUId,lastModifiedDateTime,webLink&$top=100"
  events <- pages token [] (base <> select)
  let keys = [key | (key,_,_) <- events]
      sortedKeys = sort keys
  if any ((> 1) . length) (group sortedKeys) then throwE "Calendar changed during pagination (duplicate IDs); retry the fetch." else pure ()
  prior <- ExceptT (fmap fetchResult (listEvidenceIds snapshot))
  updates <- forM events $ \(key,version,event) -> do
    selected <- either throwE pure (within bounds event)
    if not selected then pure [] else do
      old <- ExceptT (fmap fetchResult (readEvidence snapshot (EvidenceId key)))
      let Event _ _ _ _ _ _ _ _ _ _ _ _ link = event
          evidence = Evidence (EvidenceFingerprint version) (if Text.null link then [base <> "/" <> Json.escape key] else [link]) event
      pure $ case old of
        Nothing -> [NewEvidence (EvidenceId key) evidence]
        Just (Evidence fingerprint _ _) | fingerprint == EvidenceFingerprint version -> []
        Just _ -> [UpdatedEvidence (EvidenceId key) evidence]
  pure (concat updates <> map RemovedEvidence (removedIds prior sortedKeys))
  where
    fetchResult = either (\(FetchError message) -> Left message) Right
    pages token seen url
      | url `elem` seen = throwE "Calendar pagination repeated a page; retry the fetch."
      | not ("https://graph.microsoft.com/" `Text.isPrefixOf` url) = throwE "Unexpected Graph pagination URL."
      | otherwise = do
          response <- ExceptT (Http.send (HttpRequest "GET" url [("Authorization","Bearer " <> token),("Prefer","outlook.timezone=\"UTC\"")] ""))
          value <- either throwE pure (Http.requireSuccess response >>= Json.parse)
          entries <- either throwE pure (Json.member "value" value >>= Json.array >>= mapM eventValue)
          next <- either throwE pure (Json.optionalText "@odata.nextLink" value)
          rest <- maybe (pure []) (pages token (url:seen)) next
          pure (entries <> rest)

removedIds :: [EvidenceId] -> [Text] -> [EvidenceId]
removedIds prior current = map snd (sortOn fst (missing ordered current))
  where
    ordered = sortOn fst [(value,(index,key)) | (index,key@(EvidenceId value)) <- zip [0 :: Int ..] prior]
    missing [] _ = []
    missing old [] = map snd old
    missing old@((key,item):rest) now@(value:values) = case compare key value of
      LT -> item : missing rest now
      EQ -> missing rest now
      GT -> missing old values

checkedBounds :: CalendarFetch -> Either Text (Maybe Rational,Maybe Rational)
checkedBounds (CalendarFetch lower upper) = do
  from <- traverse timestamp lower
  to <- traverse timestamp upper
  case (from,to) of
    (Just start,Just end) | start > end -> Left "modifiedFrom must not be later than modifiedTo"
    _ -> Right (from,to)

within :: Maybe (Maybe Rational,Maybe Rational) -> Event -> Either Text Bool
within Nothing _ = Right True
within (Just (lower,upper)) (Event _ _ _ _ _ _ _ _ _ _ _ modified _) = do
  value <- timestamp modified
  pure (maybe True (<= value) lower && maybe True (>= value) upper)

eventValue :: JSValue -> Either Text (Text,Text,Event)
eventValue value = do
  key <- fieldText "id"
  either (Left . (("Graph event " <> key <> ": ") <>)) Right (decodeEvent key)
  where
    decodeEvent key = do
      version <- fieldText "changeKey"
      if Text.null key || Text.null version then Left "Graph event has no ID or changeKey" else pure ()
      event <- Event <$> descriptive ["subject"] value <*> descriptive ["bodyPreview"] value
        <*> (Json.member "start" value >>= eventTime) <*> (Json.member "end" value >>= eventTime)
        <*> (Json.member "organizer" value >>= person)
        <*> (Json.member "attendees" value >>= Json.array >>= mapM person)
        <*> descriptive ["location","displayName"] value
        <*> (Json.member "isAllDay" value >>= Json.boolean) <*> (Json.member "isCancelled" value >>= Json.boolean)
        <*> fieldText "type" <*> descriptive ["iCalUId"] value <*> fieldText "lastModifiedDateTime" <*> descriptive ["webLink"] value
      pure (key,version,event)
    fieldText key = Json.member key value >>= Json.text
    eventTime item = EventTime <$> (Json.member "dateTime" item >>= Json.text) <*> (Json.member "timeZone" item >>= Json.text)
    person item = Person <$> descriptive ["emailAddress","name"] item <*> descriptive ["emailAddress","address"] item

descriptive :: [Text] -> JSValue -> Either Text Text
descriptive _ JSNull = Right ""
descriptive [] value = Json.text value
descriptive (key:rest) (JSObject fields) = descriptive rest (maybe JSNull id (lookup (Text.unpack key) (fromJSObject fields)))
descriptive _ _ = Left "Expected descriptive response object"
