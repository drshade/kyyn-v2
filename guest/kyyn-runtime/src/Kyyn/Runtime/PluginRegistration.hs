module Kyyn.Runtime.PluginRegistration (encodeConnectors) where

import Data.Aeson (toJSON)
import Agentic.Aeson (fromAeson)
import Kyyn.Types.Plugin (Connector)
import Kyyn.Runtime.Contract (toWire)
import Kyyn.Runtime.Json (printValue)

encodeConnectors :: [Connector] -> Either String String
encodeConnectors = printValue . toWire . fromAeson . toJSON
