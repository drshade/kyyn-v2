{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}
module MicrosoftGraph.Types where

import GHC.Generics (Generic)
import Kyyn.Contract (Contract)

import Data.Text (Text)
data GraphAuth
  = ClientSecret { tenant :: Text, clientId :: Text, secretKey :: Text }
  | DeviceCode { tenant :: Text, clientId :: Text, tokenKey :: Text, scopes :: [Text] }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

data Person = Person { name :: Text, address :: Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
