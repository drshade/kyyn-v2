{-# LANGUAGE GADTs #-}
module Kyyn.Plumbing.Interpreter.Clock (runClockIO) where
import Data.Time (getCurrentTime)
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Plumbing.Capability.Clock
runClockIO :: IOE :> es => Eff (Clock : es) a -> Eff es a
runClockIO = interpret $ \_ CurrentTime -> liftIO getCurrentTime
