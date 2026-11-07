{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module Kyyn.Composition.Timings
  ( Timings, newTimings, observeCompilations, observeExecutions ) where

import Data.IORef
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpose, passthrough)
import qualified Effectful.Exception as Exception
import GHC.Clock (getMonotonicTimeNSec)
import Kyyn.Composition.Timing (timingEnabled, emitTiming)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestExecution

newtype Timings = Timings (IORef [(BuildIdentity,String)])

newTimings :: IO (Maybe Timings)
newTimings = do
  enabled <- timingEnabled
  if enabled then Just <$> (Timings <$> newIORef []) else pure Nothing

observeCompilations :: (IOE :> es, GuestCompilation :> es)
  => Maybe Timings -> Eff es a -> Eff es a
observeCompilations Nothing = id
observeCompilations (Just (Timings labels)) = interpose $ \_ (CompileGuest sources) -> do
  let label = show (selectedBuild sources)
  start <- liftIO getMonotonicTimeNSec
  result <- compileGuest sources `Exception.onException` liftIO (emitTiming "compile-aborted" label start)
  liftIO (emitTiming "guest-build" label start)
  case result of
    Right (CompiledProgram identity _ _) -> liftIO (modifyIORef' labels ((identity,label) :))
    Left _ -> pure ()
  pure result

observeExecutions :: (IOE :> es, GuestExecution :> es)
  => Maybe Timings -> Eff es a -> Eff es a
observeExecutions Nothing = id
observeExecutions (Just (Timings labels)) = interpose $ \env operation -> do
  let program = case operation of ExecuteCompiled value _ -> value; ExecuteGuest value _ _ -> value
      CompiledProgram identity path _ = program
  names <- liftIO (readIORef labels)
  let label = maybe path id (lookup identity names)
      step = "guest-execution"
  start <- liftIO getMonotonicTimeNSec
  passthrough env operation
    `Exception.finally` liftIO (emitTiming step label start)
