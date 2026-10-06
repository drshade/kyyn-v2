{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Runtime.PluginRegistration (encodeConnectors) where

import Kyyn.Types.Plugin (SourceConnector(..), CapturedMethod(..))
import Kyyn.Runtime.Json
import Text.JSON.Types (JSValue(JSArray))

encodeConnectors :: [SourceConnector] -> Either String String
encodeConnectors = printValue . JSArray . map connector
  where
    text = encodeWith textCodec
    connector (SourceConnector name fetch validate methods login) = record
      [("name",text name),
       ("fetch",text fetch),("validateConfig",text validate),("methods",JSArray (map method methods)),
       ("login",encodeWith (optionalCodec textCodec) login)]
    method (CapturedMethod name description implementation) = record
      [("name",text name),("description",text description),("implementation",text implementation)]
