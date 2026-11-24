{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.FlowEvents (FlowEvents(..), EventVisit(..), serviceEvents) where

import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.FlowInstance (FlowInstanceId)
import Kyyn.Porcelain.Capability.FlowWorker (WorkerVisit)

data EventVisit = EventVisit { activity :: WorkerVisit, received :: Bool } deriving (Eq, Show)

data FlowEvents :: Effect where
  ServiceEvents :: FlowInstanceId -> FlowEvents m EventVisit
type instance DispatchOf FlowEvents = Dynamic

serviceEvents :: FlowEvents :> es => FlowInstanceId -> Eff es EventVisit
serviceEvents = send . ServiceEvents
