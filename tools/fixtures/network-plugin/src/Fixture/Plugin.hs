{-# LANGUAGE OverloadedStrings #-}
module Fixture.Plugin where
import Kyyn.Plugin
connectors :: [SourceConnector]
connectors = [SourceConnector
  { name = "Network"
  , fetch = "Fixture.Fetch.fetch", validateConfig = "Fixture.Config.validate", methods = []
  , login = Just "Fixture.Login.login"
  }]
