{-# LANGUAGE OverloadedStrings #-}
module LocalFile.Plugin (description, connectors) where

import Kyyn.Plugin (SourceConnector(..), CapturedMethod(..))

description :: String
description = "Local folder text evidence"

connectors :: [SourceConnector]
connectors = [SourceConnector
  { name = "Folder"
  , fetch = "LocalFile.Folder.fetch"
  , login = Nothing
  , validateConfig = "LocalFile.Config.validate"
  , methods = [CapturedMethod
      { methodName = "content"
      , methodDescription = "Read the latest fetched text of a file by its evidence ID."
      , implementation = "LocalFile.Read.content"
      }]
  }]
