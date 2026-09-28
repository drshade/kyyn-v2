module MicrosoftGraph.Calendar (fetch) where

import Control.Monad (forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (isPrefixOf, nub)
import KyynPluginBindings
import MicrosoftGraph.Types
import MicrosoftGraph.Config (scope)
import MicrosoftGraph.Timestamp (timestamp)
import qualified MicrosoftGraph.Auth as Auth
import qualified MicrosoftGraph.Http as Http
import qualified MicrosoftGraph.Json as Json
import Text.JSON.Types (JSValue)

fetch :: CalendarConfig -> Maybe CalendarFetch -> EvidenceSnapshot Event -> Acquisition (Either FetchError [EvidenceChange Event])
fetch config@(CalendarConfig auth mailbox calendar _) options snapshot = fmap (either (Left . FetchError) Right) $ runExceptT $ do
  bounds <- either throwE pure (traverse checkedBounds options)
  token <- ExceptT (Auth.accessToken auth (scope config))
  let base = "https://graph.microsoft.com/v1.0/users/" ++ Json.escape mailbox ++
        maybe "/calendar" (("/calendars/" ++) . Json.escape) calendar ++ "/events"
      select = "?$select=id,changeKey,subject,bodyPreview,start,end,organizer,attendees,location,isAllDay,isCancelled,type,iCalUId,lastModifiedDateTime,webLink&$top=100"
  events <- pages token [] (base ++ select)
  let keys = [key | (key,_,_) <- events]
  if length keys /= length (nub keys) then throwE "Calendar changed during pagination (duplicate IDs); retry the fetch." else pure ()
  prior <- ExceptT (fmap fetchResult (listEvidenceIds snapshot))
  updates <- forM events $ \(key,version,event) -> do
    selected <- either throwE pure (within bounds event)
    if not selected then pure [] else do
      old <- ExceptT (fmap fetchResult (readEvidence snapshot (EvidenceId key)))
      let Event _ _ _ _ _ _ _ _ _ _ _ _ link = event
          evidence = Evidence (EvidenceFingerprint version) (if null link then [base ++ "/" ++ Json.escape key] else [link]) event
      pure $ case old of
        Nothing -> [NewEvidence (EvidenceId key) evidence]
        Just (Evidence fingerprint _ _) | fingerprint == EvidenceFingerprint version -> []
        Just _ -> [UpdatedEvidence (EvidenceId key) evidence]
  pure (concat updates ++ [RemovedEvidence key | key@(EvidenceId value) <- prior, value `notElem` keys])
  where
    fetchResult = either (\(FetchError message) -> Left message) Right
    pages token seen url
      | url `elem` seen = throwE "Calendar pagination repeated a page; retry the fetch."
      | not ("https://graph.microsoft.com/" `isPrefixOf` url) = throwE "Unexpected Graph pagination URL."
      | otherwise = do
          response <- ExceptT (Http.send (HttpRequest "GET" url [("Authorization","Bearer " ++ token),("Prefer","outlook.timezone=\"UTC\"")] ""))
          value <- either throwE pure (Http.requireSuccess response >>= Json.parse)
          entries <- either throwE pure (Json.member "value" value >>= Json.array >>= mapM eventValue)
          next <- either throwE pure (Json.optionalText "@odata.nextLink" value)
          rest <- maybe (pure []) (pages token (url:seen)) next
          pure (entries ++ rest)

checkedBounds :: CalendarFetch -> Either String (Maybe Rational,Maybe Rational)
checkedBounds (CalendarFetch lower upper) = do
  from <- traverse timestamp lower
  to <- traverse timestamp upper
  case (from,to) of
    (Just start,Just end) | start > end -> Left "modifiedFrom must not be later than modifiedTo"
    _ -> Right (from,to)

within :: Maybe (Maybe Rational,Maybe Rational) -> Event -> Either String Bool
within Nothing _ = Right True
within (Just (lower,upper)) (Event _ _ _ _ _ _ _ _ _ _ _ modified _) = do
  value <- timestamp modified
  pure (maybe True (<= value) lower && maybe True (>= value) upper)

eventValue :: JSValue -> Either String (String,String,Event)
eventValue value = do
  key <- fieldText "id"
  version <- fieldText "changeKey"
  if null key || null version then Left "Graph event has no ID or changeKey" else pure ()
  event <- Event <$> fieldText "subject" <*> fieldText "bodyPreview"
    <*> (Json.member "start" value >>= eventTime) <*> (Json.member "end" value >>= eventTime)
    <*> (Json.member "organizer" value >>= person)
    <*> (Json.member "attendees" value >>= Json.array >>= mapM person)
    <*> (Json.member "location" value >>= Json.member "displayName" >>= Json.text)
    <*> (Json.member "isAllDay" value >>= Json.boolean) <*> (Json.member "isCancelled" value >>= Json.boolean)
    <*> fieldText "type" <*> fieldText "iCalUId" <*> fieldText "lastModifiedDateTime" <*> fieldText "webLink"
  pure (key,version,event)
  where
    fieldText key = Json.member key value >>= Json.text
    eventTime item = EventTime <$> (Json.member "dateTime" item >>= Json.text) <*> (Json.member "timeZone" item >>= Json.text)
    person item = do
      email <- Json.member "emailAddress" item
      Person <$> (Json.member "name" email >>= Json.text) <*> (Json.member "address" email >>= Json.text)
