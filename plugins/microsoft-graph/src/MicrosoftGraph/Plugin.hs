{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Plugin (connectors) where
import Kyyn.Plugin
connectors :: [Connector]
connectors = [SourceConnector
  { name = "Calendar"
  , fetch = "MicrosoftGraph.Calendar.fetch", validateConfig = "MicrosoftGraph.Calendar.Config.validate"
  , login = Just "MicrosoftGraph.Calendar.Config.login"
  , methods = [CapturedMethod "event" "Read the latest captured calendar event." "MicrosoftGraph.Calendar.Read.event"]
  }, SourceConnector
  { name = "Mail"
  , fetch = "MicrosoftGraph.Mail.fetch", validateConfig = "MicrosoftGraph.Mail.Config.validate"
  , login = Just "MicrosoftGraph.Mail.Config.login"
  , methods =
      [ CapturedMethod "message" "Read a captured message including its text body and attachment metadata." "MicrosoftGraph.Mail.Read.message"
      , CapturedMethod "body" "Read the captured plain-text body." "MicrosoftGraph.Mail.Read.body"
      , CapturedMethod "attachments" "Read captured attachment references." "MicrosoftGraph.Mail.Read.attachments"
      ]
  }, SourceConnector
  { name = "Meetings"
  , fetch = "MicrosoftGraph.Meetings.fetch", validateConfig = "MicrosoftGraph.Meetings.Config.validate"
  , login = Just "MicrosoftGraph.Meetings.Config.login"
  , methods =
      [ CapturedMethod "artifact" "Read a captured transcript or attendance report." "MicrosoftGraph.Meetings.Read.artifact"
      , CapturedMethod "transcript" "Read captured transcript VTT text by evidence ID, without contacting Microsoft." "MicrosoftGraph.Meetings.Read.transcript"
      ]
  }, SourceConnector
  { name = "Files"
  , fetch = "MicrosoftGraph.Files.fetch", validateConfig = "MicrosoftGraph.Files.Config.validate"
  , login = Just "MicrosoftGraph.Files.Config.login"
  , methods = [CapturedMethod "file" "Read captured file metadata and its content blob." "MicrosoftGraph.Files.Read.file"]
  }, SourceConnector
  { name = "Directory"
  , fetch = "MicrosoftGraph.Directory.fetch", validateConfig = "MicrosoftGraph.Directory.Config.validate"
  , login = Just "MicrosoftGraph.Directory.Config.login"
  , methods = [CapturedMethod "directory" "Read the captured user directory snapshot." "MicrosoftGraph.Directory.Read.directory"]
  }]
