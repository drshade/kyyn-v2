{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.FlowStore
  ( FlowStore(..), startInstance, listInstances, readInstance, beginAttempt
  , reportFrontier, finishInstance, blockInstance, cancelInstance
  , queueDelivery, resolveDelivery
  ) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FlowInstance

data FlowStore :: Effect where
  StartInstance :: Maybe FlowInstanceId -> Text -> FlowLaunch -> FlowStore m (Either FlowStoreProblem FlowInstance)
  ListInstances :: FlowStore m [FlowInstance]
  ReadInstance :: FlowInstanceId -> FlowStore m (Maybe FlowInstance)
  -- Caller holds the per-instance attempt/journal lock for these worker operations.
  BeginAttempt :: FlowInstanceId -> FlowStore m (Either FlowStoreProblem FlowInstance)
  ReportFrontier :: FlowInstanceId -> [(Text,Value)] -> FlowStore m (Either FlowStoreProblem FlowInstance)
  FinishInstance :: FlowInstanceId -> FlowOutcome -> FlowStore m (Either FlowStoreProblem FlowInstance)
  BlockInstance :: FlowInstanceId -> [Diagnostic] -> FlowStore m (Either FlowStoreProblem FlowInstance)
  CancelInstance :: FlowInstanceId -> CancelScope -> FlowStore m (Either FlowStoreProblem FlowInstance)
  -- Ingress holds only the short catalog lock, never the guest's writer lock.
  QueueDelivery :: FlowInstanceId -> Text -> Text -> ReplyOrigin -> Value -> FlowStore m (Either FlowStoreProblem FlowDelivery)
  ResolveDelivery :: FlowInstanceId -> Text -> DeliveryOutcome -> FlowStore m (Either FlowStoreProblem FlowInstance)
type instance DispatchOf FlowStore = Dynamic

startInstance :: FlowStore :> es => Maybe FlowInstanceId -> Text -> FlowLaunch -> Eff es (Either FlowStoreProblem FlowInstance)
startInstance parent key = send . StartInstance parent key
listInstances :: FlowStore :> es => Eff es [FlowInstance]
listInstances = send ListInstances
readInstance :: FlowStore :> es => FlowInstanceId -> Eff es (Maybe FlowInstance)
readInstance = send . ReadInstance
beginAttempt :: FlowStore :> es => FlowInstanceId -> Eff es (Either FlowStoreProblem FlowInstance)
beginAttempt = send . BeginAttempt
reportFrontier :: FlowStore :> es => FlowInstanceId -> [(Text,Value)] -> Eff es (Either FlowStoreProblem FlowInstance)
reportFrontier identity = send . ReportFrontier identity
finishInstance :: FlowStore :> es => FlowInstanceId -> FlowOutcome -> Eff es (Either FlowStoreProblem FlowInstance)
finishInstance identity = send . FinishInstance identity
blockInstance :: FlowStore :> es => FlowInstanceId -> [Diagnostic] -> Eff es (Either FlowStoreProblem FlowInstance)
blockInstance identity = send . BlockInstance identity
cancelInstance :: FlowStore :> es => FlowInstanceId -> CancelScope -> Eff es (Either FlowStoreProblem FlowInstance)
cancelInstance identity = send . CancelInstance identity
queueDelivery :: FlowStore :> es => FlowInstanceId -> Text -> Text -> ReplyOrigin -> Value -> Eff es (Either FlowStoreProblem FlowDelivery)
queueDelivery identity delivery wait origin = send . QueueDelivery identity delivery wait origin
resolveDelivery :: FlowStore :> es => FlowInstanceId -> Text -> DeliveryOutcome -> Eff es (Either FlowStoreProblem FlowInstance)
resolveDelivery identity delivery = send . ResolveDelivery identity delivery
