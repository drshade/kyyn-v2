module LocalFile.Plugin (description, connectors) where

import Kyyn.Plugin (SourceConnector(..), AcquisitionContext(..), CapturedMethod(..))

description :: String
description = "Local folder text evidence"

connectors :: [SourceConnector]
connectors = [SourceConnector
  { name = "Folder"
  , configType = "LocalFile.Types.FolderConfig"
  , payloadType = "LocalFile.Types.Document"
  , fetch = "LocalFile.Folder.fetch"
  , fetchOptionsType = Nothing
  , acquisitionContext = FileSource
  , login = Nothing
  , validateConfig = "LocalFile.Config.validate"
  , methods = [CapturedMethod
      { methodName = "content"
      , methodDescription = "Read the latest fetched text of a file by its evidence ID."
      , inputType = "LocalFile.Types.ContentId"
      , resultType = "LocalFile.Types.Content"
      , implementation = "LocalFile.Read.content"
      }]
  }]
