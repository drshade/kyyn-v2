module Salesforce.Plugin (connectors) where
import Kyyn.Plugin (Connector(..), CapturedMethod(..), LiveQuery(..))

connectors :: [Connector]
connectors = [SourceConnector
  { name = "Query", fetch = "Salesforce.Query.fetch"
  , validateConfig = "Salesforce.Query.Config.validate", login = Just "Salesforce.Query.Config.login"
  , methods = [CapturedMethod "record" "Read a captured SOQL record by evidence ID." "Salesforce.Query.Read.record"]
  }, LiveConnector
  { name = "Live", validateConfig = "Salesforce.Live.Config.validate", login = Just "Salesforce.Live.Config.login"
  , queries = [LiveQuery "query" "Run SOQL now: at most 100 rows and 32 KiB of provider records; incomplete results are marked truncated. COUNT() returns its count in totalSize with no rows." "Salesforce.Live.query"]
  }]
