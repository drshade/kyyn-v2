module Salesforce.Types where

import GHC.Generics (Generic)
import Kyyn.Contract (Contract)
import Data.Text (Text)

data SalesforceAuth
  = ClientSecret { clientId :: Text, secretKey :: Text }
  | DeviceCode { clientId :: Text, tokenKey :: Text }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
