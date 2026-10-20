{-# LANGUAGE DuplicateRecordFields #-}
module MicrosoftGraph.Calendar.Types where

import Data.Text (Text)
import MicrosoftGraph.Types (GraphAuth, Person)

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
