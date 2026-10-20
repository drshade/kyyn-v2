{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}
module MicrosoftGraph.Types where

import Data.Text (Text)
data GraphAuth
  = ClientSecret { tenant :: Text, clientId :: Text, secretKey :: Text }
  | DeviceCode { tenant :: Text, clientId :: Text, tokenKey :: Text, scopes :: [Text] }
  deriving (Eq, Show)

data Person = Person { name :: Text, address :: Text } deriving (Eq, Show)
