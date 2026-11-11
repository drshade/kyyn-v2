module MicrosoftGraph.Mail.Types where

import GHC.Generics (Generic)
import Kyyn.Contract (Contract)

import Data.Text (Text)
import Kyyn.Plugin (BlobRef)
import MicrosoftGraph.Types (GraphAuth, Person)

data MailConfig = MailConfig
  { auth :: GraphAuth, mailbox :: Text, folders :: [MailFolder], retentionDays :: Integer }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data MailFolder = WellKnownFolder Text | FolderPath Text deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
newtype MailFetch = MailFetch { since :: Maybe Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
newtype MailPosition = MailPosition { folders :: [FolderPosition] } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data FolderPosition = FolderPosition { folderId :: Text, deltaLink :: Text, since :: Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

-- The URI identifies the Graph attachment resource, not its target cloud file.
data AttachmentContent = Stored BlobRef | Link Text deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data Attachment = Attachment
  { name :: Text, mediaType :: Text, size :: Integer, inline :: Bool, content :: AttachmentContent }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data Message = Message
  { subject :: Text, from :: Person, to :: [Person], cc :: [Person]
  , sent :: Text, received :: Text, conversationId :: Text, internetMessageId :: Text
  , firstSeenFolder :: Text, body :: Text, attachments :: [Attachment]
  } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
