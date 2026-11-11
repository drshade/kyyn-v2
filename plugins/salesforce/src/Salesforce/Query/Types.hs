module Salesforce.Query.Types where

import GHC.Generics (Generic)
import Kyyn.Contract (Contract)
import Data.Text (Text)
import Salesforce.Types (SalesforceAuth)

data QueryConfig = QueryConfig
  { instanceUrl :: Text, auth :: SalesforceAuth, apiVersion :: Text
  , query :: Text, idField :: Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

-- | The full returned object, with deterministic JSON spelling and exact numbers.
data Record = Record { recordId :: Text, json :: Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
