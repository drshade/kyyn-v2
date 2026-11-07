-- Bundled plugin contract trees must compile through the exact wire profile,
-- including empty-container element types, authentication variants and blobs.
-- This runs no provider calls and does not establish acquisition integration.
{-# LANGUAGE AllowAmbiguousTypes, TypeApplications, ScopedTypeVariables #-}
module Main (main) where

import Kyyn.Contract
import qualified GitHub.Types as P0
import qualified LocalFile.Types as P1
import qualified MicrosoftGraph.Calendar.Types as P2
import qualified MicrosoftGraph.Directory.Types as P3
import qualified MicrosoftGraph.Files.Types as P4
import qualified MicrosoftGraph.Mail.Types as P5
import qualified MicrosoftGraph.Meetings.Types as P6
import qualified MicrosoftGraph.Types as P7
import qualified Salesforce.Query.Types as P8
import qualified Salesforce.Types as P9
import qualified LocalFile.Write as P10

check :: forall a. Contract a => IO ()
check = either (fail . show) (const (pure ())) (compileContract (contract @a))

main :: IO ()
main = do
  check @P0.RepositoryConfig
  check @P0.Account
  check @P0.Comment
  check @P0.Review
  check @P0.Issue
  check @P0.PullRequest
  check @P0.CommitIdentity
  check @P0.FileChange
  check @P0.Commit
  check @P0.RepositoryItem
  check @P1.FolderConfig
  check @P1.Document
  check @P2.CalendarConfig
  check @P2.CalendarPosition
  check @P2.EventTime
  check @P2.ResponseStatus
  check @P2.Attendee
  check @P2.Event
  check @P3.DirectoryConfig
  check @P3.DirectoryUser
  check @P3.DirectoryPayload
  check @P4.FilesScope
  check @P4.FilesConfig
  check @P4.FilePayload
  check @P5.MailConfig
  check @P5.MailFolder
  check @P5.MailFetch
  check @P5.MailPosition
  check @P5.FolderPosition
  check @P5.AttachmentContent
  check @P5.Attachment
  check @P5.Message
  check @P6.MeetingsConfig
  check @P6.MeetingsFetch
  check @P6.MeetingsPosition
  check @P6.MeetingsScope
  check @P6.MeetingContext
  check @P6.MeetingStage
  check @P6.MeetingIssue
  check @P6.MeetingSkip
  check @P6.MeetingsReport
  check @P6.MeetingRef
  check @P6.ParticipantIdentity
  check @P6.AttendanceInterval
  check @P6.AttendanceRecord
  check @P6.MeetingArtifact
  check @P7.GraphAuth
  check @P7.Person
  check @P8.QueryConfig
  check @P8.Record
  check @P9.SalesforceAuth
  check @P10.Config
  check @P10.Options
  putStrLn "Bundled plugin contracts compile through the shared wire profile."
