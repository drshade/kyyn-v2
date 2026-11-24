{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Plumbing.Capability.Deadline (Deadline(..), withinMicroseconds) where

import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)

-- One budget for the entire action, including nested host callbacks.
data Deadline :: Effect where
  WithinMicroseconds :: Int -> m a -> Deadline m (Maybe a)
type instance DispatchOf Deadline = Dynamic

withinMicroseconds :: Deadline :> es => Int -> Eff es a -> Eff es (Maybe a)
withinMicroseconds duration action = send (WithinMicroseconds duration action)
