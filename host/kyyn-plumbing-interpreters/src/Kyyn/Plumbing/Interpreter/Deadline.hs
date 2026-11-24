{-# LANGUAGE GADTs #-}
module Kyyn.Plumbing.Interpreter.Deadline (runDeadlineIO) where

import Effectful (Eff, IOE, (:>), UnliftStrategy(..), withEffToIO)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift)
import Kyyn.Plumbing.Capability.Deadline
import qualified System.Timeout as Timeout

runDeadlineIO :: IOE :> es => Eff (Deadline : es) a -> Eff es a
runDeadlineIO = interpret $ \env (WithinMicroseconds duration action) ->
  localSeqUnlift env $ \unlift -> withEffToIO SeqUnlift $ \run ->
    Timeout.timeout duration (run (unlift action))
