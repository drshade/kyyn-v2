module Kyyn.Runtime.PluginRegistration (encodeConnectors) where

import Kyyn.Types.Plugin (SourceConnector(..), CapturedMethod(..))
import Kyyn.Runtime.Json
import Text.JSON.Types (JSValue(JSArray))

encodeConnectors :: [SourceConnector] -> Either String String
encodeConnectors = printValue . JSArray . map connector
  where
    text = encodeWith stringCodec
    connector (SourceConnector name config payload fetch validate methods options login) = record
      [("name",text name),("configType",text config),("payloadType",text payload),
       ("fetch",text fetch),("validateConfig",text validate),("methods",JSArray (map method methods)),
       ("fetchOptionsType",encodeWith (optionalCodec stringCodec) options),
       ("login",encodeWith (optionalCodec stringCodec) login)]
    method (CapturedMethod name description input result implementation) = record
      [("name",text name),("description",text description),("inputType",text input),
       ("resultType",text result),("implementation",text implementation)]
