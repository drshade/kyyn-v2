module Salesforce.Live.Types where

import GHC.Generics (Generic)
import Kyyn.Contract (Contract)
import Data.Text (Text)
import Salesforce.Types (SalesforceAuth)

data LiveConfig = LiveConfig
  { instanceUrl :: Text, auth :: SalesforceAuth, apiVersion :: Text }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

newtype Soql = Soql { query :: Text }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

data QueryResult
  = Records { rows :: [Row], totalSize :: Int, truncated :: Bool }
  | Rejected { errorCode :: Text, message :: Text }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

newtype Row = Row { fields :: [Field] }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data Field = Field { name :: Text, value :: FieldValue }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
-- Exact numbers remain decimal text; nested objects and arrays are explicitly JSON.
data FieldValue = Null | Boolean Bool | Number Text | TextValue Text | JsonValue Text
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
