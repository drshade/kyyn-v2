module FolderSchema where

data Config = Config { directory :: FilePath, recursive :: Bool } deriving (Eq, Show)
data Document = Document { text :: String } deriving (Eq, Show)
