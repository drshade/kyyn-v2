{-# LANGUAGE GADTs, RankNTypes, OverloadedRecordDot #-}
-- Flow observation transport and the scope of a pure Tool program.
module Kyyn.Runtime.Flow (programScope, flowObservation, exchangeObservation) where

import qualified Agentic.Runtime as A
import Agentic.Journal (journalKeyValue)
import Kyyn.Types.FlowObservation
import Kyyn.Runtime.ModelWire (valueCodec)
import Kyyn.Types.Program (Program)
import Kyyn.Runtime.Plugin (exchange)
import Kyyn.Runtime.Transport (Transport)
import Kyyn.Runtime.Json (Codec(..), fields, record, encodeWith, optionalCodec)

-- Program has no exception-catching operation. Explicit outcomes are visible
-- here; IO failures during its later interpretation are not. ExceptT failure
-- observation is supplied by upstream exceptTScope over this base hook.
programScope :: A.Scope (Program calls)
programScope = A.Scope $ \enter returned exited body -> do
  entered <- enter
  case entered of
    Left result -> pure result
    Right () -> do
      outcome <- body
      case outcome of
        Left result -> exited A.Failed Nothing >> pure result
        Right value -> returned value

flowObservation :: A.Summary -> FlowObservation
flowObservation summary = FlowObservation (FlowSummary (A.summaryValue summary))
  (OperationIdentity . journalKeyValue . (`A.journalKey` summary.occurrence) <$> operation)
  where
    operation = case summary.happened of
      A.Executing (A.KeyedOperation key) -> Just key
      A.Restored key -> Just key
      _ -> Nothing

exchangeObservation :: Transport -> Integer -> FlowObservation -> IO ()
exchangeObservation transport requestId (FlowObservation (FlowSummary summary) operation) = exchange transport requestId
  "flow" "observe" (record [("summary", encodeWith valueCodec summary),
    ("operation", encodeWith (optionalCodec valueCodec) (fmap (\(OperationIdentity key) -> key) operation))])
  (Codec (const (record [])) (\value -> fields [] value >> Right ()))
