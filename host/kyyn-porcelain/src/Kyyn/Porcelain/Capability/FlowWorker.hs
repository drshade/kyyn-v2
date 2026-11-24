{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.FlowWorker
  (FlowWorker(..), WorkerVisit(..), combineVisits, visitInstance, writerBusy) where

import Data.Time (UTCTime)
import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.FlowInstance (FlowInstanceId)

data WorkerVisit = WriterBusy | NoWork | Advanced | Blocked | PollRetry UTCTime deriving (Eq, Show)
data FlowWorker :: Effect where
  VisitInstance :: FlowInstanceId -> FlowWorker m WorkerVisit
  WriterIsBusy :: FlowInstanceId -> FlowWorker m Bool
type instance DispatchOf FlowWorker = Dynamic

visitInstance :: FlowWorker :> es => FlowInstanceId -> Eff es WorkerVisit
visitInstance = send . VisitInstance
-- Inspection only: it does not initialize a journal or advance an instance.
writerBusy :: FlowWorker :> es => FlowInstanceId -> Eff es Bool
writerBusy = send . WriterIsBusy

combineVisits :: [WorkerVisit] -> WorkerVisit
combineVisits visits
  | Blocked `elem` visits = Blocked
  | time:times <- [due | PollRetry due <- visits] = PollRetry (minimum (time:times))
  | Advanced `elem` visits = Advanced
  | WriterBusy `elem` visits = WriterBusy
  | otherwise = NoWork
