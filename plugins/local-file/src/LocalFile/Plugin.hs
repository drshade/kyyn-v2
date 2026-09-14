module LocalFile.Plugin (description, connectors) where

import Kyyn.Plugin (SourceConnector(..))

description :: String
description = "Local folder text evidence"

connectors :: [SourceConnector]
connectors = [SourceConnector
  { name = "Folder"
  , configType = "LocalFile.Types.FolderConfig"
  , payloadType = "LocalFile.Types.Document"
  , fetch = "LocalFile.Folder.fetch"
  , validateConfig = "LocalFile.Config.validate"
  }]
