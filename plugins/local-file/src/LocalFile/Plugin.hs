{-# LANGUAGE OverloadedStrings #-}
module LocalFile.Plugin (description, connectors) where

import Kyyn.Plugin (Connector(..), CapturedMethod(..))

description :: String
description = "Local folder evidence and UTF-8 file outputs"

connectors :: [Connector]
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
  }, SinkConnector
  { name = "File"
  , validateConfig = "LocalFile.Write.validate"
  , publish = "LocalFile.Write.publish"
  , defaultOptions = "LocalFile.Write.defaults"
  }]
