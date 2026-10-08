module LocalFile.Types where

import Data.Text (Text)

-- | Read UTF-8 text files from a local folder.
data FolderConfig = FolderConfig
  { -- | Directory to read, relative to the KB or absolute.
    directory :: FilePath
  , -- | Include files in child directories.
    recursive :: Bool
  } deriving (Eq, Show)

-- | Captured contents of one text file.
data Document = Document { text :: Text } deriving (Eq, Show)

type ContentId = Text
type Content = Text
