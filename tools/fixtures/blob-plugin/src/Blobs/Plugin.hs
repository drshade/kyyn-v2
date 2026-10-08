{-# LANGUAGE OverloadedStrings #-}
module Blobs.Plugin where
import Kyyn.Plugin
connectors :: [Connector]
connectors = [SourceConnector
  { name = "Files", fetch = "Blobs.Source.fetch", validateConfig = "Blobs.Source.validate"
  , login = Nothing
  , methods = [CapturedMethod "attachment" "Read captured attachment reference" "Blobs.Source.attachment"]
  }]
