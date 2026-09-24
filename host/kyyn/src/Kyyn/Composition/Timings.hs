{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module Kyyn.Composition.Timings
  ( Timings, newTimings, observeCompilations, observeExecutions, observeProcesses ) where

import Data.IORef
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpose, passthrough)
import qualified Effectful.Exception as Exception
import GHC.Clock (getMonotonicTimeNSec)
import Kyyn.Domain.Path (relativeName)
import Kyyn.MicroHs.Timing (timingEnabled, emitTiming)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestExecution
import Kyyn.Plumbing.Capability.ProcessExecution
import System.FilePath (takeFileName)

data Timings = Timings (IORef Int) (IORef [(BuildIdentity,String)])

newTimings :: IO (Maybe Timings)
newTimings = do
  enabled <- timingEnabled
  if enabled then Just <$> (Timings <$> newIORef 0 <*> newIORef []) else pure Nothing

observeCompilations :: (IOE :> es, GuestCompilation :> es)
  => Maybe Timings -> Eff es a -> Eff es a
observeCompilations Nothing = id
observeCompilations (Just (Timings calls labels)) = interpose $ \_ (CompileGuest sources) -> do
  let label = relativeName (selectedEntry sources)
  before <- liftIO (readIORef calls)
  start <- liftIO getMonotonicTimeNSec
  result <- compileGuest sources `Exception.onException` liftIO (emitTiming "compile-aborted" label start)
  after <- liftIO (readIORef calls)
  liftIO (emitTiming (if after == before then "compile-hit" else "compile-miss") label start)
  case result of
    Right (CompiledProgram identity _) -> liftIO (modifyIORef' labels ((identity,label) :))
    Left _ -> pure ()
  pure result

observeExecutions :: (IOE :> es, GuestExecution :> es)
  => Maybe Timings -> Eff es a -> Eff es a
observeExecutions Nothing = id
observeExecutions (Just (Timings _ labels)) = interpose $ \env operation -> do
  let program = case operation of ExecuteCompiled value _ -> value; ExecuteGuest value _ _ -> value
      CompiledProgram identity (path,_) = program
  names <- liftIO (readIORef labels)
  let label = maybe (relativeName path) id (lookup identity names)
      step = if label == "KyynPluginRegistrationEntry.hs" then "plugin-registration" else "guest-execution"
  start <- liftIO getMonotonicTimeNSec
  passthrough env operation
    `Exception.finally` liftIO (emitTiming step label start)

observeProcesses :: (IOE :> es, ProcessExecution :> es)
  => Maybe Timings -> Eff es a -> Eff es a
observeProcesses Nothing = id
observeProcesses (Just (Timings calls _)) = interpose $ \env operation@(WithProcess (ProcessSpec executable _ _ _) _) -> do
  if takeFileName executable == "mhs" then liftIO (modifyIORef' calls (+ 1)) else pure ()
  passthrough env operation
