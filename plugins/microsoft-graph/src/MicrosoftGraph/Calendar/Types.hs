module MicrosoftGraph.Calendar.Types where

import GHC.Generics (Generic)
import Kyyn.Contract (Contract)

import Data.Text (Text)
import MicrosoftGraph.Types (GraphAuth, Person)

data CalendarConfig = CalendarConfig
  { auth :: GraphAuth
  , mailbox :: Text
  , calendarId :: Maybe Text
  , sharedCalendar :: Bool
  , windowStart :: Text
  , windowEnd :: Text
  } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

newtype CalendarPosition = CalendarPosition { deltaLink :: Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

data EventTime = EventTime { dateTime :: Text, timeZone :: Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data ResponseStatus = ResponseStatus
  { response :: Text, time :: Maybe Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data Attendee = Attendee
  { name :: Text, address :: Text, status :: Maybe ResponseStatus } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data Event = Event
  { subject :: Text, bodyPreview :: Text
  , start :: EventTime, end :: EventTime
  , organizer :: Person, attendees :: [Attendee]
  , location :: Text, isAllDay :: Bool, isCancelled :: Bool
  , eventType :: Text, iCalUId :: Text
  , lastModifiedDateTime :: Text, webLink :: Text
  , responseStatus :: Maybe ResponseStatus
  } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
type EventId = Text
