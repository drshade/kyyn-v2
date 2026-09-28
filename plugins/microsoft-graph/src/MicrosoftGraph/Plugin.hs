module MicrosoftGraph.Plugin (connectors) where
import Kyyn.Plugin
connectors :: [SourceConnector]
connectors = [SourceConnector
  { name = "Calendar", configType = "MicrosoftGraph.Types.CalendarConfig", payloadType = "MicrosoftGraph.Types.Event"
  , fetch = "MicrosoftGraph.Calendar.fetch", validateConfig = "MicrosoftGraph.Config.validate"
  , fetchOptionsType = Just "MicrosoftGraph.Types.CalendarFetch", acquisitionContext = NetworkSource
  , login = Just "MicrosoftGraph.Login.login"
  , methods = [CapturedMethod "event" "Read the latest captured calendar event." "MicrosoftGraph.Types.EventId"
      "MicrosoftGraph.Types.Event" "MicrosoftGraph.Read.event"]
  }]
