module Kyyn.Runtime.PluginRegistration (encodeConnectors) where

import Kyyn.Types.Plugin (SourceConnector(..))
import Kyyn.Runtime.Json
import Text.JSON.Types (JSValue(JSArray))

encodeConnectors :: [SourceConnector] -> Either String String
encodeConnectors = printValue . JSArray . map connector
  where
    text = encodeWith stringCodec
    connector (SourceConnector name config payload fetch validate) = record
      [("name",text name),("configType",text config),("payloadType",text payload),
       ("fetch",text fetch),("validateConfig",text validate)]
