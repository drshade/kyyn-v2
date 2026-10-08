{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Plugin (connectors) where
import Kyyn.Plugin
connectors :: [SourceConnector]
connectors = [SourceConnector
  { name = "Calendar"
  , fetch = "MicrosoftGraph.Calendar.fetch", validateConfig = "MicrosoftGraph.Config.validate"
  , login = Just "MicrosoftGraph.Login.login"
  , methods = [CapturedMethod "event" "Read the latest captured calendar event." "MicrosoftGraph.Read.event"]
  }, SourceConnector
  { name = "Mail"
  , fetch = "MicrosoftGraph.Mail.fetch", validateConfig = "MicrosoftGraph.Mail.Config.validate"
  , login = Just "MicrosoftGraph.Mail.Config.login"
  , methods =
      [ CapturedMethod "message" "Read a captured message including its text body and attachment metadata." "MicrosoftGraph.Mail.Read.message"
      , CapturedMethod "body" "Read the captured plain-text body." "MicrosoftGraph.Mail.Read.body"
      , CapturedMethod "attachments" "Read captured attachment references." "MicrosoftGraph.Mail.Read.attachments"
      ]
  }]
