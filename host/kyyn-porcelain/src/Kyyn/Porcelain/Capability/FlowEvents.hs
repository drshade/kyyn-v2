{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.FlowEvents (FlowEvents(..), dispatchEvents) where

import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.FlowInstance (FlowInstanceId)
import Kyyn.Porcelain.Capability.FlowWorker (WorkerVisit)

data FlowEvents :: Effect where
  DispatchEvents :: FlowInstanceId -> FlowEvents m WorkerVisit
type instance DispatchOf FlowEvents = Dynamic

dispatchEvents :: FlowEvents :> es => FlowInstanceId -> Eff es WorkerVisit
dispatchEvents = send . DispatchEvents
