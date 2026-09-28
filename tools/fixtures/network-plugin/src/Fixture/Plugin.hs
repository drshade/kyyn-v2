module Fixture.Plugin where
import Kyyn.Plugin
connectors :: [SourceConnector]
connectors = [SourceConnector
  { name = "Network", configType = "Fixture.Types.Config", payloadType = "Fixture.Types.Payload"
  , fetch = "Fixture.Fetch.fetch", validateConfig = "Fixture.Config.validate", methods = []
  , fetchOptionsType = Nothing, acquisitionContext = NetworkSource, login = Just "Fixture.Login.login"
  }]
