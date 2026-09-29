module MicrosoftGraph.Plugin (connectors) where
import Kyyn.Plugin
connectors :: [SourceConnector]
connectors = [SourceConnector
  { name = "Calendar"
  , fetch = "MicrosoftGraph.Calendar.fetch", validateConfig = "MicrosoftGraph.Config.validate"
  , login = Just "MicrosoftGraph.Login.login"
  , methods = [CapturedMethod "event" "Read the latest captured calendar event." "MicrosoftGraph.Read.event"]
  }]
