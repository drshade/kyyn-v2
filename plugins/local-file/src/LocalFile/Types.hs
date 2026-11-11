module LocalFile.Types where

import GHC.Generics (Generic)
import Kyyn.Contract (Contract)

import Data.Text (Text)

-- | Read UTF-8 text files from a local folder.
data FolderConfig = FolderConfig
  { -- | Directory to read, relative to the KB or absolute.
    directory :: Text
  , -- | Include files in child directories.
    recursive :: Bool
  } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

-- | Captured contents of one text file.
data Document = Document { text :: Text } deriving stock (Eq, Show, Generic) deriving anyclass (Contract)

type ContentId = Text
type Content = Text
