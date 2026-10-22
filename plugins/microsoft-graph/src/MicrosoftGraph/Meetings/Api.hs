{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Meetings.Api (Pending(..), discover, artifacts, capture, targets, Discovery(..)) where

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

data Discovery = Discovered [Text] [MeetingSkip] | DeniedUser | UnavailableUser

targets :: Text -> GraphAuth -> Acquisition payload (Either Text [Text])
targets _ DeviceCode {} = pure (Right [graphApiBase <> "me"])
targets token ClientSecret {} = runExceptT $ do
  users <- ExceptT (requiredRequest (collection token (graphApiBase <> "users?$select=id")))
  ids <- either throwE pure (mapM (required "id") users)
  pure [graphApiBase <> "users/" <> Json.escape key | key <- ids]

requestHeaders :: Text -> [(Text,Text)]
requestHeaders token = [("Authorization","Bearer " <> token),("Prefer","outlook.timezone=\"UTC\"")]

data RequestError = Denied Text | MailboxUnavailable | Failed Text

document :: Text -> Text -> Acquisition payload (Either RequestError JSValue)
document token url
  | not (graphApiBase `Text.isPrefixOf` url) = pure (Left (Failed "Unexpected Graph pagination URL"))
  | otherwise = do
      result <- Http.send (HttpRequest "GET" url (requestHeaders token) "")
      pure $ case result of
        Right (HttpResponse 403 _ _) -> Left (Denied url)
        Right (HttpResponse 404 _ body)
          | "/calendarView" `Text.isInfixOf` url,
            Right code <- Json.parse body >>= Json.member "error" >>= required "code",
            code `elem` ["MailboxNotEnabledForRESTAPI","MailboxNotSupportedForRESTAPI"] -> Left MailboxUnavailable
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
  Left MailboxUnavailable -> Left "Mailbox is not available through the Graph calendar API"
  Left (Failed message) -> Left message
  Right value -> Right (Just value,[])

requiredRequest :: Acquisition payload (Either RequestError a) -> Acquisition payload (Either Text a)
requiredRequest = fmap $ \result -> case result of
  Left (Denied _) -> Left "Access denied during Meetings identity or calendar discovery; check consent."
  Left MailboxUnavailable -> Left "Mailbox is not available through the Graph calendar API"
  Left (Failed message) -> Left message
  Right value -> Right value

-- Discover join URLs, rather than treating a recurring calendar event as an artifact.
discover :: Text -> Text -> Bool -> Text -> Text -> Acquisition payload (Either Text Discovery)
discover token base application since now = runExceptT $ do
  let url = base <> "/calendarView?startDateTime=" <> Json.escape since <>
        "&endDateTime=" <> Json.escape now <> "&$select=id,end,isOrganizer,isOnlineMeeting,onlineMeetingProvider,onlineMeeting"
  response <- ExceptT (Right <$> collection token url)
  case response of
    Left (Denied _) | application -> pure DeniedUser
    Left MailboxUnavailable | application -> pure UnavailableUser
    Left (Denied _) -> throwE "Access denied during Meetings calendar discovery; check consent."
    Left MailboxUnavailable -> throwE "Mailbox is not available through the Graph calendar API"
    Left (Failed message) -> throwE message
    Right events -> do
      results <- either throwE pure (mapM endedMeeting events)
      pure (Discovered (concatMap fst results) (concatMap snd results))
  where
    endedMeeting value = do
      online <- optional Json.boolean "isOnlineMeeting" value
      organizer <- if application && online == Just True then Just <$> (Json.member "isOrganizer" value >>= Json.boolean) else Right Nothing
      if online /= Just True || application && organizer /= Just True then pure ([],[]) else do
        end <- Json.member "end" value
        zone <- required "timeZone" end
        date <- required "dateTime" end
        if zone /= "UTC" then Left "Calendar discovery did not return UTC event times" else pure ()
        let utc = if "Z" `Text.isSuffixOf` date then date else date <> "Z"
        at <- timestamp utc
        lower <- timestamp since
        upper <- timestamp now
        if at < lower || at > upper then pure ([],[]) else do
          eventId <- Json.optionalText "id" value
          provider <- Json.optionalText "onlineMeetingProvider" value
          let skip why = Right ([],[MeetingSkip (maybe "calendar event without ID" id eventId) why])
          if provider /= Just "teamsForBusiness"
            then skip ("Unsupported online meeting provider: " <> maybe "unspecified" id provider)
            else case Json.member "onlineMeeting" value >>= required "joinUrl" of
              Left problem -> skip ("Missing or invalid join URL: " <> problem)
              Right url -> pure ([url],[])

artifacts :: Text -> Text -> Text -> Acquisition payload (Either Text ([Pending],[Text],[MeetingSkip]))
artifacts token base joinUrl = runExceptT $ do
  let filterValue = "JoinWebUrl eq '" <> Text.replace "'" "''" joinUrl <> "'"
  (resolved,denied) <- ExceptT (optionalRequest (collection token (base <> "/onlineMeetings?$filter=" <> Json.escape filterValue)))
  case resolved of
    Nothing -> pure ([],denied,[])
    Just matches -> case matches of
      [] -> skip "Calendar meeting could not be resolved"
      [value] -> case meetingRef value of
        Left problem -> skip ("Incomplete meeting metadata: " <> problem)
        Right meeting@(MeetingRef key _ _ _) -> do
          let url = base <> "/onlineMeetings/" <> Json.escape key
          (transcripts,transcriptDenied) <- ExceptT (optionalRequest (collection token (url <> "/transcripts")))
          (reports,reportDenied) <- ExceptT (optionalRequest (collection token (url <> "/attendanceReports")))
          items <- either throwE pure $ (++) <$> mapM (pending meeting "Transcript" "createdDateTime" "endDateTime") (maybe [] id transcripts)
            <*> mapM (pending meeting "Attendance" "meetingStartDateTime" "meetingEndDateTime") (maybe [] id reports)
          pure (items,transcriptDenied ++ reportDenied,[])
      _ -> skip "Join URL resolved to multiple online meetings"
  where
    skip why = pure ([],[],[MeetingSkip joinUrl why])
    meetingRef value = do
      key <- required "id" value
      subject <- maybe "" id <$> Json.optionalText "subject" value
      organizer <- Json.member "participants" value >>= Json.member "organizer" >>= Json.member "identity"
        >>= Json.member "user" >>= required "id"
      pure (MeetingRef key joinUrl subject organizer)
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
