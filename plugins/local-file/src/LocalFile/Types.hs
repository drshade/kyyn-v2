module LocalFile.Types where

-- | Read UTF-8 text files from a local folder.
data FolderConfig = FolderConfig
  { -- | Absolute directory to read.
    directory :: FilePath
  , -- | Include files in child directories.
    recursive :: Bool
  } deriving (Eq, Show)

-- | Captured contents of one text file.
data Document = Document { text :: String } deriving (Eq, Show)

type ContentId = String
type Content = String
