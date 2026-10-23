module MicrosoftGraph.Directory.Types where
import Data.Text (Text)
import MicrosoftGraph.Types (GraphAuth)

data DirectoryConfig = DirectoryConfig { auth :: GraphAuth } deriving (Eq, Show)
data DirectoryUser = DirectoryUser
  { id :: Text, displayName :: Maybe Text, givenName :: Maybe Text
  , surname :: Maybe Text, mail :: Maybe Text, userPrincipalName :: Maybe Text
  , accountEnabled :: Maybe Bool, userType :: Maybe Text }
  deriving (Eq, Show)
data DirectoryPayload = DirectoryPayload { users :: [DirectoryUser] } deriving (Eq, Show)
