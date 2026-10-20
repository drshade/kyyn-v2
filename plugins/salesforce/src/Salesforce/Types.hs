module Salesforce.Types where
import Data.Text (Text)

data SalesforceAuth
  = ClientSecret { clientId :: Text, secretKey :: Text }
  | DeviceCode { clientId :: Text, tokenKey :: Text }
  deriving (Eq, Show)
