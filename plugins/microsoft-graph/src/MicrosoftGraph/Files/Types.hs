{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
module MicrosoftGraph.Files.Types where

import GHC.Generics (Generic)
import Kyyn.Contract (Contract)
import Data.Text (Text)
import Kyyn.Plugin (BlobRef)
import MicrosoftGraph.Types (GraphAuth)

data FilesScope
  = SiteLibrary { site :: Text, library :: Text }
  | OneDrive { user :: Text }
  | SharedUrl { url :: Text }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data FilesConfig = FilesConfig
  { auth :: GraphAuth, scope :: FilesScope, itemPath :: Text, includeGlobs :: [Text] }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
data FilePayload = FilePayload
  { name :: Text, path :: Text, webUrl :: Text, mediaType :: Text, size :: Integer
  , modified :: Text, modifiedBy :: Text, cTag :: Maybe Text, content :: BlobRef }
  deriving stock (Eq, Show, Generic) deriving anyclass (Contract)
