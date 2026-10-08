{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Runtime.PluginRegistration (encodeConnectors) where

import Kyyn.Types.Plugin (Connector(..), CapturedMethod(..))
import Kyyn.Runtime.Json
import Text.JSON.Types (JSValue(JSArray))

encodeConnectors :: [Connector] -> Either String String
encodeConnectors = printValue . JSArray . map connector
  where
    text = encodeWith textCodec
    connector (SourceConnector name fetch validate methods login) = record
      [("name",text name),
       ("fetch",text fetch),("validateConfig",text validate),("methods",JSArray (map method methods)),
       ("login",encodeWith (optionalCodec textCodec) login)]
    connector (SinkConnector name validate publish defaults) = record
      [("name",text name),("validateConfig",text validate),("publish",text publish),("defaultOptions",text defaults)]
    method (CapturedMethod name description implementation) = record
      [("name",text name),("description",text description),("implementation",text implementation)]
