{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Meetings.Api (Pending(..), discover, artifacts, capture, userBase) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Plugin.Host
import MicrosoftGraph.Config (graphApiBase)
import MicrosoftGraph.Types (GraphAuth(..))
import MicrosoftGraph.Meetings.Types hiding (id)
import MicrosoftGraph.Timestamp (timestamp)
import qualified MicrosoftGraph.Http as Http
import qualified MicrosoftGraph.Json as Json
import Text.JSON.Types (JSValue(..), fromJSObject)

data Pending = Pending Text Text Text Text MeetingRef -- kind, provider id, first time, end, meeting

userBase :: MeetingsConfig -> Text
userBase (MeetingsConfig auth user _) = graphApiBase <> case auth of
  DeviceCode {} -> "me"
  ClientSecret {} -> "users/" <> Json.escape user

requestHeaders :: Text -> [(Text,Text)]
requestHeaders token = [("Authorization","Bearer " <> token),("Prefer","outlook.timezone=\"UTC\"")]

data RequestError = Denied Text | Failed Text

document :: Text -> Text -> Acquisition payload (Either RequestError JSValue)
document token url
  | not (graphApiBase `Text.isPrefixOf` url) = pure (Left (Failed "Unexpected Graph pagination URL"))
  | otherwise = do
      result <- Http.send (HttpRequest "GET" url (requestHeaders token) "")
      pure $ case result of
        Right (HttpResponse 403 _ _) -> Left (Denied url)
        _ -> either (Left . Failed) Right (result >>= Http.requireSuccess >>= Json.parse)

collection :: Text -> Text -> Acquisition payload (Either RequestError [JSValue])
collection token = runExceptT . pages []
  where
    pages seen url
      | url `elem` seen = throwE (Failed "Meetings pagination repeated a page")
      | otherwise = do
          value <- ExceptT (document token url)
          entries <- either (throwE . Failed) pure (Json.member "value" value >>= Json.array)
          next <- either (throwE . Failed) pure (Json.optionalText "@odata.nextLink" value)
          rest <- maybe (pure []) (pages (url:seen)) next
          pure (entries ++ rest)

-- A denial on any page discards the incomplete collection. It is not evidence
-- that the collection was empty, and no artifact identity is marked captured.
optionalRequest :: Acquisition payload (Either RequestError a)
  -> Acquisition payload (Either Text (Maybe a,[Text]))
optionalRequest = fmap $ \result -> case result of
  Left (Denied url) -> Right (Nothing,[url])
  Left (Failed message) -> Left message
  Right value -> Right (Just value,[])

requiredRequest :: Acquisition payload (Either RequestError a) -> Acquisition payload (Either Text a)
requiredRequest = fmap $ \result -> case result of
  Left (Denied _) -> Left "Access denied during Meetings identity or calendar discovery; check consent."
  Left (Failed message) -> Left message
  Right value -> Right value

-- Discover join URLs, rather than treating a recurring calendar event as an artifact.
discover :: Text -> MeetingsConfig -> Text -> Text -> Acquisition payload (Either Text [Text])
discover token config@(MeetingsConfig auth user _) since now = runExceptT $ do
  case auth of
    ClientSecret {} -> pure ()
    DeviceCode {} -> do
      me <- ExceptT (requiredRequest (document token (graphApiBase <> "me?$select=id")))
      actual <- either throwE pure (required "id" me)
      if Text.toLower actual == Text.toLower user then pure ()
        else throwE "Meetings userId must match the signed-in user's Entra object ID"
  let url = userBase config <> "/calendarView?startDateTime=" <> Json.escape since <>
        "&endDateTime=" <> Json.escape now <> "&$select=end,isOnlineMeeting,onlineMeetingProvider,onlineMeeting"
  events <- ExceptT (requiredRequest (collection token url))
  either throwE pure (concat <$> mapM endedMeeting events)
  where
    endedMeeting value = do
      online <- optional Json.boolean "isOnlineMeeting" value
      if online /= Just True then pure [] else do
        end <- Json.member "end" value
        zone <- required "timeZone" end
        date <- required "dateTime" end
        if zone /= "UTC" then Left "Calendar discovery did not return UTC event times" else pure ()
        let utc = if "Z" `Text.isSuffixOf` date then date else date <> "Z"
        at <- timestamp utc
        lower <- timestamp since
        upper <- timestamp now
        if at < lower || at > upper then pure [] else do
          provider <- required "onlineMeetingProvider" value
          if provider /= "teamsForBusiness" then Left "Meetings supports Teams online meetings only" else pure ()
          meeting <- Json.member "onlineMeeting" value
          url <- required "joinUrl" meeting
          pure [url]

artifacts :: Text -> Text -> Text -> Acquisition payload (Either Text ([Pending],[Text]))
artifacts token base joinUrl = runExceptT $ do
  let filterValue = "JoinWebUrl eq '" <> Text.replace "'" "''" joinUrl <> "'"
  (resolved,denied) <- ExceptT (optionalRequest (collection token (base <> "/onlineMeetings?$filter=" <> Json.escape filterValue)))
  case resolved of
    Nothing -> pure ([],denied)
    Just matches -> do
      meeting <- case matches of
        [value] -> either throwE pure $ do
          key <- required "id" value
          subject <- maybe "" id <$> Json.optionalText "subject" value
          organizer <- Json.member "participants" value >>= Json.member "organizer" >>= Json.member "identity"
            >>= Json.member "user" >>= required "id"
          pure (MeetingRef key joinUrl subject organizer)
        [] -> throwE "Calendar meeting could not be resolved; check meeting access and supported meeting type"
        _ -> throwE "Join URL resolved to multiple online meetings"
      let MeetingRef key _ _ _ = meeting
          url = base <> "/onlineMeetings/" <> Json.escape key
      (transcripts,transcriptDenied) <- ExceptT (optionalRequest (collection token (url <> "/transcripts")))
      (reports,reportDenied) <- ExceptT (optionalRequest (collection token (url <> "/attendanceReports")))
      items <- either throwE pure $ (++) <$> mapM (pending meeting "Transcript" "createdDateTime" "endDateTime") (maybe [] id transcripts)
        <*> mapM (pending meeting "Attendance" "meetingStartDateTime" "meetingEndDateTime") (maybe [] id reports)
      pure (items,transcriptDenied ++ reportDenied)
  where
    pending meeting kind firstField endField value = do
      key <- required "id" value
      first <- required firstField value
      end <- required endField value
      firstAt <- timestamp first
      endAt <- timestamp end
      if kind == "Attendance" && firstAt > endAt then Left "Meeting artifact ends before it starts" else pure ()
      pure (Pending kind key first end meeting)

capture :: Text -> Text -> Pending -> Acquisition MeetingArtifact (Either Text (Maybe MeetingArtifact,[Text]))
capture token base (Pending kind key first end meeting@(MeetingRef meetingId _ _ _)) = runExceptT $ do
  let url = base <> "/onlineMeetings/" <> Json.escape meetingId
  case kind of
    "Transcript" -> do
      let contentUrl = url <> "/transcripts/" <> Json.escape key <> "/content?$format=text/vtt"
      content <- ExceptT (Http.downloadOptional (BlobDownload
        (HttpRequest "GET" contentUrl (requestHeaders token) "")
        (Just "transcript.vtt") (Just "text/vtt")))
      pure (Transcript meeting first end <$> content, [contentUrl | Nothing <- [content]])
    "Attendance" -> do
      (records,denied) <- ExceptT (optionalRequest (collection token (url <> "/attendanceReports/" <> Json.escape key <> "/attendanceRecords")))
      attendees <- either throwE pure (traverse (mapM attendance) records)
      pure (Attendance meeting first end <$> attendees,denied)
    _ -> throwE "Unsupported meeting artifact kind"

attendance :: JSValue -> Either Text AttendanceRecord
attendance value = AttendanceRecord <$> optional participant "identity" value
  <*> Json.optionalText "emailAddress" value <*> Json.optionalText "role" value
  <*> optional (fmap toInteger . Json.integer) "totalAttendanceInSeconds" value
  <*> (Json.member "attendanceIntervals" value >>= Json.array >>= mapM interval)
  where
    participant item = ParticipantIdentity <$> Json.optionalText "id" item
      <*> Json.optionalText "displayName" item <*> Json.optionalText "tenantId" item
      <*> Json.optionalText "@odata.type" item <*> Json.optionalText "azureCommunicationServicesResourceId" item
    interval item = AttendanceInterval <$> optional time "joinDateTime" item <*> optional time "leaveDateTime" item
      <*> optional (fmap toInteger . Json.integer) "durationInSeconds" item
    time item = do
      text <- Json.text item
      _ <- timestamp text
      pure text

required :: Text -> JSValue -> Either Text Text
required key value = do
  text <- Json.member key value >>= Json.text
  if Text.null text then Left ("Empty response field: " <> key) else Right text

optional :: (JSValue -> Either Text a) -> Text -> JSValue -> Either Text (Maybe a)
optional decode key (JSObject fields) = case lookup (Text.unpack key) (fromJSObject fields) of
  Nothing -> Right Nothing
  Just JSNull -> Right Nothing
  Just value -> Just <$> decode value
optional _ _ _ = Left "Expected response object"
