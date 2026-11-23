{-# LANGUAGE OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Domain.FlowDispatch (beginDispatch, completeDispatch, blockDispatch) where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.List (find)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FlowInstance

-- Caller owns the adapter lock. Readiness is rechecked under the catalog lock;
-- manual fulfilment and cancellation can race with an external invocation.
beginDispatch :: Text -> FlowInstance -> Either FlowStoreProblem (Bool,FlowInstance)
beginDispatch key current
  | Finished{} <- current.status = Right (False,current)
  | current.retryRequired = Right (False,current)
  | otherwise = case find ((== key) . (.waitId)) current.waits of
      Just wait | wait.waitStatus == Open, Just state <- wait.adapter,
        null state.dispatchProblems, state.dispatch `elem` [Pending,Started] -> do
          next <- change key (\adapter -> Right adapter {dispatch = Started}) current
          Right (True,next)
      _ -> Right (False,current)

-- A successful result belongs to the call even if the wait closed meanwhile.
completeDispatch :: Text -> Value -> FlowInstance -> Either FlowStoreProblem FlowInstance
completeDispatch key value = change key $ \state -> case state.dispatch of
  Started -> Right state {dispatch = DispatchCompleted,cursor = Just value,dispatchProblems = []}
  _ -> Left (InvalidTransition "Dispatch completion requires a started call")

blockDispatch :: Text -> [Diagnostic] -> FlowInstance -> Either FlowStoreProblem FlowInstance
blockDispatch key problems = change key (\state -> Right state {dispatchProblems = problems})

change :: Text -> (EventAdapter -> Either FlowStoreProblem EventAdapter) -> FlowInstance
  -> Either FlowStoreProblem FlowInstance
change key update current = case find ((== key) . (.waitId)) current.waits of
  Just wait | Just state <- wait.adapter -> do
    changed <- update state
    pure current { waits = [if old.waitId == key then old {adapter = Just changed} else old | old <- current.waits] }
  _ -> Left (InvalidTransition "Missing event wait")
