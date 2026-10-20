{-# LANGUAGE OverloadedStrings #-}
module Salesforce.Plugin (connectors) where
import Kyyn.Plugin

connectors :: [Connector]
connectors = [SourceConnector
  { name = "Query", fetch = "Salesforce.Query.fetch"
  , validateConfig = "Salesforce.Query.Config.validate", login = Just "Salesforce.Query.Config.login"
  , methods = [CapturedMethod "record" "Read a captured SOQL record by evidence ID." "Salesforce.Query.Read.record"]
  }]
