{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Calendar (fetch) where

import qualified Data.Text as Text
import Data.Text (Text)
import Control.Monad (forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (groupBy, sort, sortOn)
import Kyyn.Plugin
import Kyyn.Plugin.Host
import MicrosoftGraph.Types
import MicrosoftGraph.Config (scope, window)
import qualified MicrosoftGraph.Auth as Auth
import qualified MicrosoftGraph.Http as Http
import qualified MicrosoftGraph.Json as Json
import Text.JSON.Types (JSValue(..), fromJSObject)

fetch :: CalendarConfig -> FetchContext CalendarPosition -> EvidenceSnapshot Event -> Acquisition Event (Either FetchError (FetchResult Event CalendarPosition))
fetch config@(CalendarConfig auth mailbox _ _ _ _) (FetchContext _ priorPosition) snapshot = fmap (either (Left . FetchError) Right) $ runExceptT $ do
  (start,end) <- either throwE pure (window config)
  token <- ExceptT (Auth.accessToken auth (scope config))
  let base = "https://graph.microsoft.com/v1.0/users/" <> Json.escape mailbox
      initial = base <> "/calendarView/delta?startDateTime=" <> Json.escape start <> "&endDateTime=" <> Json.escape end
  roundResult <- pages token [] (maybe initial (\(CalendarPosition link) -> link) priorPosition)
  (baseline,entries,next) <- case roundResult of
    Just (entries,next) -> pure (case priorPosition of Nothing -> True; Just _ -> False,entries,next)
    Nothing -> do
      reset <- pages token [] initial
      case reset of
        Nothing -> throwE "Calendar sync reset failed; retry the fetch."
        Just (entries,next) -> pure (True,entries,next)
  let events = lastCopies entries
  updates <- forM events $ \(key,item) -> do
    old <- ExceptT (fmap fetchResult (readEvidence snapshot (EvidenceId key)))
    pure $ case item of
      Nothing -> case old of Nothing -> []; Just _ -> [RemovedEvidence (EvidenceId key)]
      Just (version,event) ->
        let Event _ _ _ _ _ _ _ _ _ _ _ _ link = event
            evidence = Evidence (EvidenceFingerprint version)
              (if Text.null link then [base <> "/events/" <> Json.escape key] else [link]) event
        in case old of
          Nothing -> [NewEvidence (EvidenceId key) evidence]
          Just (Evidence fingerprint _ _) | fingerprint == EvidenceFingerprint version -> []
          Just _ -> [UpdatedEvidence (EvidenceId key) evidence]
  removed <- if baseline then do
    prior <- ExceptT (fmap fetchResult (listEvidenceIds snapshot))
    pure (map RemovedEvidence (removedIds prior (sort (map fst events))))
    else pure []
  pure (FetchResult (concat updates <> removed) (CalendarPosition next))
  where
    fetchResult = either (\(FetchError message) -> Left message) Right
    pages token seen url
      | url `elem` seen = throwE "Calendar pagination repeated a page; retry the fetch."
      | not ("https://graph.microsoft.com/" `Text.isPrefixOf` url) = throwE "Unexpected Graph pagination URL."
      | otherwise = do
          response@(HttpResponse status _ body) <- ExceptT (Http.send (HttpRequest "GET" url
            [("Authorization","Bearer " <> token),("Prefer","outlook.timezone=\"UTC\", odata.maxpagesize=100")] ""))
          if status == 410 || (status >= 400 && errorCode body == Just "syncStateNotFound") then pure Nothing else do
            value <- either throwE pure (Http.requireSuccess response >>= Json.parse)
            entries <- either throwE pure (Json.member "value" value >>= Json.array >>= mapM deltaValue)
            next <- either throwE pure (Json.optionalText "@odata.nextLink" value)
            case next of
              Just link -> fmap (fmap (\(rest,final) -> (entries <> rest,final))) (pages token (url:seen) link)
              Nothing -> do
                final <- either throwE pure (Json.member "@odata.deltaLink" value >>= Json.text)
                if "https://graph.microsoft.com/" `Text.isPrefixOf` final
                  then pure (Just (entries,final)) else throwE "Unexpected Graph delta URL."

errorCode :: Text -> Maybe Text
errorCode body = either (const Nothing) Just (Json.parse body >>= Json.member "error" >>= Json.member "code" >>= Json.text)

lastCopies :: [(Text,a)] -> [(Text,a)]
lastCopies entries = map snd (sortOn fst [last group | group <- grouped])
  where grouped = groupBy (\(_,a) (_,b) -> fst a == fst b) (sortOn (fst . snd) (zip [0 :: Int ..] entries))

deltaValue :: JSValue -> Either Text (Text,Maybe (Text,Event))
deltaValue value@(JSObject fields) | Just _ <- lookup "@removed" (fromJSObject fields) = do
  key <- Json.member "id" value >>= Json.text
  if Text.null key then Left "Graph removal has no ID" else Right (key,Nothing)
deltaValue value = do
  (key,version,event) <- eventValue value
  pure (key,Just (version,event))

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

eventValue :: JSValue -> Either Text (Text,Text,Event)
eventValue value = do
  key <- fieldText "id"
  either (Left . (("Graph event " <> key <> ": ") <>)) Right (decodeEvent key)
  where
    decodeEvent key = do
      etag <- Json.optionalText "@odata.etag" value
      version <- maybe (fieldText "changeKey") Right etag
      if Text.null key || Text.null version then Left "Graph event has no ID or version" else pure ()
      event <- Event <$> descriptive ["subject"] value <*> descriptive ["bodyPreview"] value
        <*> (Json.member "start" value >>= eventTime) <*> (Json.member "end" value >>= eventTime)
        <*> person (optionalField "organizer" value)
        <*> (case optionalField "attendees" value of JSNull -> Right []; entries -> Json.array entries >>= mapM person)
        <*> descriptive ["location","displayName"] value
        <*> flag "isAllDay" <*> flag "isCancelled"
        <*> descriptive ["type"] value <*> descriptive ["iCalUId"] value <*> descriptive ["lastModifiedDateTime"] value <*> descriptive ["webLink"] value
      pure (key,version,event)
    fieldText key = Json.member key value >>= Json.text
    flag key = case optionalField key value of JSNull -> Right False; item -> Json.boolean item
    eventTime item = EventTime <$> (Json.member "dateTime" item >>= Json.text) <*> (Json.member "timeZone" item >>= Json.text)
    person item = Person <$> descriptive ["emailAddress","name"] item <*> descriptive ["emailAddress","address"] item

optionalField :: Text -> JSValue -> JSValue
optionalField key (JSObject fields) = maybe JSNull id (lookup (Text.unpack key) (fromJSObject fields))
optionalField _ _ = JSNull

descriptive :: [Text] -> JSValue -> Either Text Text
descriptive _ JSNull = Right ""
descriptive [] value = Json.text value
descriptive (key:rest) (JSObject fields) = descriptive rest (maybe JSNull id (lookup (Text.unpack key) (fromJSObject fields)))
descriptive _ _ = Left "Expected descriptive response object"
