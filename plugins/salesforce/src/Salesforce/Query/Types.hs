module Salesforce.Query.Types where
import Data.Text (Text)
import Salesforce.Types (SalesforceAuth)

data QueryConfig = QueryConfig
  { instanceUrl :: Text, auth :: SalesforceAuth, apiVersion :: Text
  , query :: Text, idField :: Text } deriving (Eq, Show)

-- | The full returned object, with deterministic JSON spelling and exact numbers.
data Record = Record { recordId :: Text, json :: Text } deriving (Eq, Show)
