module FolderSchema where

data FetchOptions = FetchOptions { label :: String } deriving (Eq, Show)

data Config = Config { directory :: FilePath, recursive :: Bool } deriving (Eq, Show)
data Document = Document { text :: String } deriving (Eq, Show)
