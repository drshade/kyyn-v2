{-# LANGUAGE GADTs, OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Runtime.FlowControl (exchangeFlowControl) where

import Agentic.Journal (DurableKey(..), durableKeyText)
import Data.Aeson (toJSON)
import Agentic.Aeson (toAeson, fromAeson)
import Kyyn.Types.FlowStatus (CancelScope(..), encodeStatus, decodeStatus)
import qualified Data.Text as Text
import Kyyn.Contract.Wire (toWire)
import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Kyyn.Types.FlowControl (FlowControl(..))
import Kyyn.Runtime.Plugin (exchange, eitherCodec)
import Kyyn.Runtime.Transport (Transport)
import Kyyn.Runtime.Json (Codec(..), record, fields, encodeWith, textCodec, boolCodec)

exchangeFlowControl :: Transport -> Integer -> FlowControl a -> IO a
exchangeFlowControl transport requestId (StartChild key (RecipeId child) inputContract outputContract input) = exchange transport requestId "flow-control" "start"
  (record [("namespace",encodeWith textCodec key.namespace),("key",encodeWith textCodec (durableKeyText key)),
    ("child",toJSON child),("inputContract",toJSON inputContract),("outputContract",toJSON outputContract),("input",toWire input)]) (eitherCodec textCodec)

exchangeFlowControl transport requestId (InspectChild identity outputContract) = exchange transport requestId "flow-control" "inspect"
  (record [("id",encodeWith textCodec identity),("outputContract",toJSON outputContract)])
  (eitherCodec (Codec (toAeson . encodeStatus id) (either (Left . Text.unpack) Right . decodeStatus Right . fromAeson)))
exchangeFlowControl transport requestId (CancelChild identity outputContract scope) = exchange transport requestId "flow-control" "cancel"
  (record [("id",encodeWith textCodec identity),("outputContract",toJSON outputContract),
    ("descendants",encodeWith boolCodec (scope == FlowAndDescendants))])
  (eitherCodec (Codec (const (record [])) (\value -> fields [] value >> Right ())))
