{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module Kyyn.Plumbing.Interpreter.ConcurrentExecution
  ( runConcurrentExecutionIO, runConcurrentExecutionObserved, ConcurrentEvent(..) ) where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Concurrent.MVar (newMVar, modifyMVar, newEmptyMVar, putMVar, readMVar)
import qualified Control.Exception as Exception
import Effectful (Eff, IOE, (:>), UnliftStrategy(..), Persistence(..), Limit(..), withEffToIO)
import Effectful.Dispatch.Dynamic (interpret, localUnlift)
import Kyyn.Plumbing.Capability.ConcurrentExecution
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))

data ConcurrentEvent = RoundStarted Int Int | WorkerStarted | WorkerFinished | RoundFinished

runConcurrentExecutionIO :: (IOE :> es, Failure :> es)
  => Int -> Eff (ConcurrentExecution : es) a -> Eff es a
runConcurrentExecutionIO width = runConcurrentExecutionObserved width (const (pure ()))

runConcurrentExecutionObserved :: (IOE :> es, Failure :> es)
  => Int -> (ConcurrentEvent -> IO ()) -> Eff (ConcurrentExecution : es) a -> Eff es a
runConcurrentExecutionObserved configured observe = interpret $ \env -> \case
  ConcurrencyWidth -> pure configured
  ConcurrentlyBounded width actions
    | width < 1 || width > configured || configured > 8 -> raiseFailure (RuntimeUnavailable (ProcessDiagnostic ReadOutput "Invalid concurrent execution width"))
    | otherwise -> localUnlift env (ConcUnlift Ephemeral Unlimited) $ \unlift ->
        withEffToIO (ConcUnlift Ephemeral Unlimited) $ \run ->
          Exception.bracket_ (observe (RoundStarted width (length actions))) (observe RoundFinished) $
            pooled width observe (map (run . unlift) actions)

pooled :: Int -> (ConcurrentEvent -> IO ()) -> [IO a] -> IO [a]
pooled width observe actions = do
  outputs <- mapM (const newEmptyMVar) actions
  queue <- newMVar (zip actions outputs)
  let worker = do
        selected <- modifyMVar queue $ \pending -> case pending of
          [] -> pure ([],Nothing)
          value:rest -> pure (rest,Just value)
        case selected of
          Nothing -> pure ()
          Just (action,output) -> do
            value <- Exception.bracket_ (observe WorkerStarted) (observe WorkerFinished) action
            putMVar output value
            worker
  mapConcurrently_ (const worker) [1 .. min width (length actions)]
  mapM readMVar outputs
