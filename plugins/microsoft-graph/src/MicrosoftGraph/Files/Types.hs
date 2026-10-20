{-# LANGUAGE DuplicateRecordFields #-}
module MicrosoftGraph.Files.Types where
import Data.Text (Text)
import Kyyn.Plugin (BlobRef)
import MicrosoftGraph.Types (GraphAuth)

data FilesScope
  = SiteLibrary { site :: Text, library :: Text }
  | OneDrive { user :: Text }
  | SharedUrl { url :: Text }
  deriving (Eq, Show)
data FilesConfig = FilesConfig
  { auth :: GraphAuth, scope :: FilesScope, itemPath :: Text, includeGlobs :: [Text] }
  deriving (Eq, Show)
data FilePayload = FilePayload
  { name :: Text, path :: Text, webUrl :: Text, mediaType :: Text, size :: Integer
  , modified :: Text, modifiedBy :: Text, cTag :: Maybe Text, content :: BlobRef }
  deriving (Eq, Show)
