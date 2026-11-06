{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies #-}
module MicrosoftGraph.Directory.Types where

import GHC.Generics (Generic)
import Kyyn.Contract (Contract)
import Data.Text (Text)
import MicrosoftGraph.Types (GraphAuth)

data DirectoryConfig = DirectoryConfig { auth :: GraphAuth } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data DirectoryUser = DirectoryUser
  { id :: Text, displayName :: Maybe Text, givenName :: Maybe Text
  , surname :: Maybe Text, mail :: Maybe Text, userPrincipalName :: Maybe Text
  , accountEnabled :: Maybe Bool, userType :: Maybe Text }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data DirectoryPayload = DirectoryPayload { users :: [DirectoryUser] } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
