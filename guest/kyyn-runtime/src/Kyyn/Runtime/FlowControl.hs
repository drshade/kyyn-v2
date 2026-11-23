{-# LANGUAGE GADTs, OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Runtime.FlowControl (exchangeFlowControl) where

import Agentic.Journal (DurableKey(..), durableKeyText)
import Data.Aeson (toJSON)
import Kyyn.Contract.Wire (toWire)
import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Kyyn.Types.FlowControl (FlowControl(..))
import Kyyn.Runtime.Plugin (exchange, eitherCodec)
import Kyyn.Runtime.Transport (Transport)
import Kyyn.Runtime.Json (record, encodeWith, textCodec)

exchangeFlowControl :: Transport -> Integer -> FlowControl a -> IO a
exchangeFlowControl transport requestId (StartChild key (RecipeId child) inputContract outputContract input) = exchange transport requestId "flow-control" "start"
  (record [("namespace",encodeWith textCodec key.namespace),("key",encodeWith textCodec (durableKeyText key)),
    ("child",toJSON child),("inputContract",toJSON inputContract),("outputContract",toJSON outputContract),("input",toWire input)]) (eitherCodec textCodec)
