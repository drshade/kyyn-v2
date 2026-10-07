{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}
module MicrosoftGraph.Types where

import Data.Text (Text)
data GraphAuth
  = ClientSecret { tenant :: Text, clientId :: Text, secretKey :: Text }
  | DeviceCode { tenant :: Text, clientId :: Text, tokenKey :: Text }
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
data Event = Event
  { subject :: Text, bodyPreview :: Text
  , start :: EventTime, end :: EventTime
  , organizer :: Person, attendees :: [Person]
  , location :: Text, isAllDay :: Bool, isCancelled :: Bool
  , eventType :: Text, iCalUId :: Text
  , lastModifiedDateTime :: Text, webLink :: Text
  } deriving (Eq, Show)
type EventId = Text
