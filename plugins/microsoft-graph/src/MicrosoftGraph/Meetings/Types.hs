module MicrosoftGraph.Meetings.Types where

import GHC.Generics (Generic)
import Kyyn.Contract (Contract)

import Data.Text (Text)
import Kyyn.Plugin (BlobRef)
import MicrosoftGraph.Types (GraphAuth)

data MeetingsConfig = MeetingsConfig
  { auth :: GraphAuth, retentionDays :: Integer } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data MeetingsFetch = MeetingsFetch { since :: Maybe Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data MeetingsPosition = MeetingsPosition { lastSuccessfulFetch :: Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data MeetingsScope = DelegatedMailbox | EnabledMemberMailboxes { examinedUserIds :: [Text] }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data MeetingContext = SignedInUser | DirectoryUser { userId :: Text } deriving stock (Eq, Ord, Show, Generic) deriving anyclass (Contract)
data MeetingStage = CalendarDiscovery | MeetingResolution | TranscriptListing
  | AttendanceListing | TranscriptContent | AttendanceRecords deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data MeetingIssue = MeetingIssue
  { context :: MeetingContext, stage :: MeetingStage, reference :: Maybe Text, reason :: Text }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data MeetingSkip = MeetingSkip
  { context :: MeetingContext, reference :: Maybe Text, reason :: Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data MeetingsReport = MeetingsReport
  { since :: Text, until :: Text, scope :: MeetingsScope
  , deniedRequests :: [MeetingIssue], unavailableUsers :: [MeetingIssue]
  , skippedMeetings :: [MeetingSkip], coverageLimits :: [MeetingIssue] } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data MeetingRef = MeetingRef
  { onlineMeetingId :: Text, joinUrl :: Text, subject :: Text, organizer :: Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data ParticipantIdentity = ParticipantIdentity
  { id :: Maybe Text, displayName :: Maybe Text, tenantId :: Maybe Text
  , providerType :: Maybe Text, azureCommunicationServicesResourceId :: Maybe Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data AttendanceInterval = AttendanceInterval
  { joinDateTime :: Maybe Text, leaveDateTime :: Maybe Text, durationInSeconds :: Maybe Integer } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data AttendanceRecord = AttendanceRecord
  { identity :: Maybe ParticipantIdentity, emailAddress :: Maybe Text
  , role :: Maybe Text, totalAttendanceInSeconds :: Maybe Integer
  , attendanceIntervals :: [AttendanceInterval] } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data MeetingArtifact
  = Transcript { meeting :: MeetingRef, created :: Text, ended :: Text, content :: BlobRef }
  | Attendance { meeting :: MeetingRef, started :: Text, ended :: Text, attendees :: [AttendanceRecord] }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
