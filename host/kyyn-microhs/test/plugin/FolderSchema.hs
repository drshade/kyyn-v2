module FolderSchema where

import Data.Text (Text)

data FetchOptions = FetchOptions { label :: Text } deriving (Eq, Show)

data Config = Config { directory :: FilePath, recursive :: Bool } deriving (Eq, Show)
data Document = Document { text :: Text } deriving (Eq, Show)
