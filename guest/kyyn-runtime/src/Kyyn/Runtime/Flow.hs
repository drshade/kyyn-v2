{-# LANGUAGE GADTs, RankNTypes #-}
-- Recipe-only observation transport and the scope of a pure Tool program.
module Kyyn.Runtime.Flow (programScope, exchangeObservation) where

import qualified Agentic.Runtime as A
import Agentic.Aeson (toAeson)
import Kyyn.Types.Program (Program)
import Kyyn.Runtime.Plugin (exchange)
import Kyyn.Runtime.Transport (Transport)
import Kyyn.Runtime.Json (Codec(..), fields, record)

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

exchangeObservation :: Transport -> Integer -> A.Summary -> IO ()
exchangeObservation transport requestId summary = exchange transport requestId
  "flow" "observe" (toAeson (A.summaryValue summary))
  (Codec (const (record [])) (\value -> fields [] value >> Right ()))
