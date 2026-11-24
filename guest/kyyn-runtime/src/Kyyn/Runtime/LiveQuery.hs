{-# LANGUAGE GADTs, OverloadedStrings #-}
module Kyyn.Runtime.LiveQuery (exchangeLiveQuery) where

import Data.Aeson (toJSON)
import Agentic.Aeson (fromAeson)
import Kyyn.Contract.Wire (toWire)
import Kyyn.Types.LiveQuery
import Kyyn.Runtime.Plugin (exchange, eitherCodec)
import Kyyn.Runtime.Transport (Transport)
import Kyyn.Runtime.Json (Codec(..), record)

exchangeLiveQuery :: Transport -> Integer -> LiveQueryCall a -> IO a
exchangeLiveQuery transport requestId (InvokeLiveQuery (LiveQueryBinding plugin connector instanceName method) inputContract outputContract input) =
  exchange transport requestId "plugin" "query"
    (record [("plugin",toJSON plugin),("connectorType",toJSON connector),("instance",toJSON instanceName),
      ("method",toJSON method),("inputContract",toJSON inputContract),("outputContract",toJSON outputContract),("input",toWire input)])
    (eitherCodec (Codec toWire (Right . fromAeson)))
