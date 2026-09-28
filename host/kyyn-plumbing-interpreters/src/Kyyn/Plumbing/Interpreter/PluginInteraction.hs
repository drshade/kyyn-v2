{-# LANGUAGE GADTs #-}
module Kyyn.Plumbing.Interpreter.PluginInteraction (runWaitingIO, runLoginInteractionIO) where

import Control.Concurrent (threadDelay)
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Plumbing.Capability.PluginInteraction
import System.IO (hPutStrLn, hFlush, stderr)

runWaitingIO :: IOE :> es => Eff (Waiting : es) a -> Eff es a
runWaitingIO = interpret $ \_ (WaitSeconds seconds) -> liftIO (wait seconds)
  where
    wait n | n <= 0 = pure ()
           | otherwise = threadDelay 1000000 >> wait (n - 1)

runLoginInteractionIO :: IOE :> es => Eff (LoginInteraction : es) a -> Eff es a
runLoginInteractionIO = interpret $ \_ (DisplayInstructions message) ->
  liftIO (hPutStrLn stderr message >> hFlush stderr)
