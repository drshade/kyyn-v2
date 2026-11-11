module Kyyn.Runtime.PluginRegistration (encodeConnectors) where

import Data.Aeson (toJSON)
import Kyyn.Types.Plugin (Connector)
import Kyyn.Runtime.Json (printValue)

encodeConnectors :: [Connector] -> Either String String
encodeConnectors = printValue . toJSON
