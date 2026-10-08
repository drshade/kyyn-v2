{-# LANGUAGE DuplicateRecordFields #-}
module MicrosoftGraph.Mail.Types where

import Data.Text (Text)
import Kyyn.Plugin (BlobRef)
import MicrosoftGraph.Types (GraphAuth, Person)

data MailConfig = MailConfig
  { auth :: GraphAuth, mailbox :: Text, folders :: [MailFolder], retentionDays :: Integer }
  deriving (Eq, Show)
data MailFolder = WellKnownFolder Text | FolderPath Text deriving (Eq, Show)
newtype MailFetch = MailFetch { since :: Maybe Text } deriving (Eq, Show)
newtype MailPosition = MailPosition { folders :: [FolderPosition] } deriving (Eq, Show)
data FolderPosition = FolderPosition { folderId :: Text, deltaLink :: Text, since :: Text } deriving (Eq, Show)

-- The URI identifies the Graph attachment resource, not its target cloud file.
data AttachmentContent = Stored BlobRef | Link Text deriving (Eq, Show)
data Attachment = Attachment
  { name :: Text, mediaType :: Text, size :: Integer, inline :: Bool, content :: AttachmentContent }
  deriving (Eq, Show)
data Message = Message
  { subject :: Text, from :: Person, to :: [Person], cc :: [Person]
  , sent :: Text, received :: Text, conversationId :: Text, internetMessageId :: Text
  , firstSeenFolder :: Text, body :: Text, attachments :: [Attachment]
  } deriving (Eq, Show)
