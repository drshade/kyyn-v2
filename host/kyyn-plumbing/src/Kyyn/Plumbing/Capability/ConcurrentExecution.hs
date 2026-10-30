{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.ConcurrentExecution
  ( ConcurrentExecution(..), concurrencyWidth, concurrentlyBounded ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)

data ConcurrentExecution :: Effect where
  ConcurrencyWidth :: ConcurrentExecution m Int
  ConcurrentlyBounded :: Int -> [m a] -> ConcurrentExecution m [a]

type instance DispatchOf ConcurrentExecution = Dynamic

concurrencyWidth :: ConcurrentExecution :> es => Eff es Int
concurrencyWidth = send ConcurrencyWidth

concurrentlyBounded :: ConcurrentExecution :> es => Int -> [Eff es a] -> Eff es [a]
concurrentlyBounded width = send . ConcurrentlyBounded width
