{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}
module MicrosoftGraph.Types where

import Data.Text (Text)
data GraphAuth
  = ClientSecret { tenant :: Text, clientId :: Text, secretKey :: Text }
  | DeviceCode { tenant :: Text, clientId :: Text, tokenKey :: Text, scopes :: [Text] }
  deriving (Eq, Show)

data CalendarConfig = CalendarConfig
  { auth :: GraphAuth
  , mailbox :: Text
  , calendarId :: Maybe Text
  , sharedCalendar :: Bool
  , windowStart :: Text
  , windowEnd :: Text
  } deriving (Eq, Show)

newtype CalendarPosition = CalendarPosition { deltaLink :: Text } deriving (Eq, Show)

data EventTime = EventTime { dateTime :: Text, timeZone :: Text } deriving (Eq, Show)
data Person = Person { name :: Text, address :: Text } deriving (Eq, Show)
data ResponseStatus = ResponseStatus
  { response :: Text, time :: Maybe Text } deriving (Eq, Show)
data Attendee = Attendee
  { name :: Text, address :: Text, status :: Maybe ResponseStatus } deriving (Eq, Show)
data Event = Event
  { subject :: Text, bodyPreview :: Text
  , start :: EventTime, end :: EventTime
  , organizer :: Person, attendees :: [Attendee]
  , location :: Text, isAllDay :: Bool, isCancelled :: Bool
  , eventType :: Text, iCalUId :: Text
  , lastModifiedDateTime :: Text, webLink :: Text
  , responseStatus :: Maybe ResponseStatus
  } deriving (Eq, Show)
type EventId = Text
