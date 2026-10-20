{-# LANGUAGE DuplicateRecordFields #-}
module MicrosoftGraph.Meetings.Types where

import Data.Text (Text)
import Kyyn.Plugin (BlobRef)
import MicrosoftGraph.Types (GraphAuth)

data MeetingsConfig = MeetingsConfig
  { auth :: GraphAuth, userId :: Text, retentionDays :: Integer } deriving (Eq, Show)
data MeetingsFetch = MeetingsFetch { since :: Maybe Text } deriving (Eq, Show)
data MeetingsPosition = MeetingsPosition deriving (Eq, Show)
data MeetingRef = MeetingRef
  { onlineMeetingId :: Text, joinUrl :: Text, subject :: Text, organizer :: Text } deriving (Eq, Show)
data ParticipantIdentity = ParticipantIdentity
  { id :: Maybe Text, displayName :: Maybe Text, tenantId :: Maybe Text } deriving (Eq, Show)
data AttendanceInterval = AttendanceInterval
  { joinDateTime :: Maybe Text, leaveDateTime :: Maybe Text, durationInSeconds :: Maybe Integer } deriving (Eq, Show)
data AttendanceRecord = AttendanceRecord
  { identity :: Maybe ParticipantIdentity, emailAddress :: Maybe Text
  , role :: Maybe Text, totalAttendanceInSeconds :: Maybe Integer
  , attendanceIntervals :: [AttendanceInterval] } deriving (Eq, Show)
data MeetingArtifact
  = Transcript { meeting :: MeetingRef, created :: Text, ended :: Text, content :: BlobRef }
  | Attendance { meeting :: MeetingRef, started :: Text, ended :: Text, attendees :: [AttendanceRecord] }
  deriving (Eq, Show)
