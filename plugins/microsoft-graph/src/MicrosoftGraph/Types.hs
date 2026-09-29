{-# LANGUAGE DuplicateRecordFields #-}
module MicrosoftGraph.Types where

data GraphAuth
  = ClientSecret { tenant :: String, clientId :: String, secretKey :: String }
  | DeviceCode { tenant :: String, clientId :: String, tokenKey :: String }
  deriving (Eq, Show)

data CalendarConfig = CalendarConfig
  { auth :: GraphAuth
  , mailbox :: String
  , calendarId :: Maybe String
  , sharedCalendar :: Bool
  } deriving (Eq, Show)

data CalendarFetch = CalendarFetch
  { modifiedFrom :: Maybe String, modifiedTo :: Maybe String } deriving (Eq, Show)

data EventTime = EventTime { dateTime :: String, timeZone :: String } deriving (Eq, Show)
data Person = Person { name :: String, address :: String } deriving (Eq, Show)
data Event = Event
  { subject :: String, bodyPreview :: String
  , start :: EventTime, end :: EventTime
  , organizer :: Person, attendees :: [Person]
  , location :: String, isAllDay :: Bool, isCancelled :: Bool
  , eventType :: String, iCalUId :: String
  , lastModifiedDateTime :: String, webLink :: String
  } deriving (Eq, Show)
type EventId = String
