module MicrosoftGraph.Teams.Types where

import Data.Text (Text)
import GHC.Generics (Generic)
import Kyyn.Contract (Contract)
import MicrosoftGraph.Types (GraphAuth)

data TeamsConfig = TeamsConfig
  { auth :: GraphAuth, chatId :: Text, respondentId :: Text }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

newtype Question = Question { text :: Text }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

data Cursor = Cursor
  { questionId :: Text, questionCreatedAt :: Text, nextPage :: Maybe Text }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

data Reply = Reply
  { messageId :: Text, senderId :: Text, createdAt :: Text
  , contentType :: Text, content :: Text }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

-- The earliest eligible message is retained until all pages have been examined.
data ConversationCursor = ConversationCursor
  { sent :: Cursor, earliest :: Maybe Reply }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

data ChatReply = ChatReply
  { message :: Reply, text :: Text }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
