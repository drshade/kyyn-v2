{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.FlowStore
  ( FlowStore(..), readDescendant, cancelDescendant, startInstance, listInstances, readInstance, beginAttempt
  , reportFrontier, finishInstance, blockInstance, cancelInstance
  , queueDelivery, queueNewDelivery, resolveDelivery, startPreparedInstance, startNewPreparedInstance, readExecutionBundle, readBundleDescription, clearInstances, linkAttempt, blockAttempt, retryInstance
  ) where

import Kyyn.Domain.RecipeRunId (RecipeRunId)
import Data.Aeson (Value)
import Data.Text (Text)
import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FlowBundleId (FlowBundleId)
import Kyyn.Porcelain.Capability.FlowPreparation (PreparedFlow, FlowBundle)
import Kyyn.Domain.FlowInstance

data FlowStore :: Effect where
  StartInstance :: Maybe FlowInstanceId -> Text -> FlowLaunch -> FlowStore m (Either FlowStoreProblem FlowInstance)
  -- Publish the immutable bundle and its first catalog reference under one lock.
  StartPreparedInstance :: Maybe FlowInstanceId -> Maybe Text -> PreparedFlow -> FlowStore m (Either FlowStoreProblem FlowInstance)
  ReadBundleDescription :: FlowBundleId -> FlowStore m (Either [Diagnostic] FlowBundle)
  ReadExecutionBundle :: FlowBundleId -> FlowStore m (Either [Diagnostic] FlowBundle)
  ClearInstances :: [FlowInstanceId] -> FlowStore m (Either FlowStoreProblem [FlowInstanceId])
  ListInstances :: FlowStore m [FlowInstance]
  ReadDescendant :: FlowInstanceId -> FlowInstanceId -> FlowStore m (Either FlowStoreProblem FlowInstance)
  CancelDescendant :: FlowInstanceId -> FlowInstanceId -> CancelScope -> FlowStore m (Either FlowStoreProblem FlowInstance)
  ReadInstance :: FlowInstanceId -> FlowStore m (Maybe FlowInstance)
  -- Caller holds the per-instance attempt/journal lock for these worker operations.
  LinkAttempt :: FlowInstanceId -> RecipeRunId -> FlowStore m (Either FlowStoreProblem FlowInstance)
  BeginAttempt :: FlowInstanceId -> FlowStore m (Either FlowStoreProblem FlowInstance)
  ReportFrontier :: FlowInstanceId -> [(Text,Value,WaitKind)] -> FlowStore m (Either FlowStoreProblem FlowInstance)
  FinishInstance :: FlowInstanceId -> FlowOutcome -> FlowStore m (Either FlowStoreProblem FlowInstance)
  -- An empty list clears a block after the caller revalidates the pinned execution.
  BlockAttempt :: FlowInstanceId -> [Diagnostic] -> FlowStore m (Either FlowStoreProblem FlowInstance)
  RetryInstance :: FlowInstanceId -> FlowStore m (Either FlowStoreProblem FlowInstance)
  BlockInstance :: FlowInstanceId -> [Diagnostic] -> FlowStore m (Either FlowStoreProblem FlowInstance)
  CancelInstance :: FlowInstanceId -> CancelScope -> FlowStore m (Either FlowStoreProblem FlowInstance)
  -- Ingress holds only the short catalog lock, never the guest's writer lock.
  QueueDelivery :: FlowInstanceId -> Maybe Text -> Text -> ReplyOrigin -> Value -> FlowStore m (Either FlowStoreProblem FlowDelivery)
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
reportFrontier :: FlowStore :> es => FlowInstanceId -> [(Text,Value,WaitKind)] -> Eff es (Either FlowStoreProblem FlowInstance)
reportFrontier identity = send . ReportFrontier identity
finishInstance :: FlowStore :> es => FlowInstanceId -> FlowOutcome -> Eff es (Either FlowStoreProblem FlowInstance)
finishInstance identity = send . FinishInstance identity
blockInstance :: FlowStore :> es => FlowInstanceId -> [Diagnostic] -> Eff es (Either FlowStoreProblem FlowInstance)
blockInstance identity = send . BlockInstance identity
cancelInstance :: FlowStore :> es => FlowInstanceId -> CancelScope -> Eff es (Either FlowStoreProblem FlowInstance)
cancelInstance identity = send . CancelInstance identity
queueDelivery :: FlowStore :> es => FlowInstanceId -> Text -> Text -> ReplyOrigin -> Value -> Eff es (Either FlowStoreProblem FlowDelivery)
queueDelivery identity delivery wait origin = send . QueueDelivery identity (Just delivery) wait origin
resolveDelivery :: FlowStore :> es => FlowInstanceId -> Text -> DeliveryOutcome -> Eff es (Either FlowStoreProblem FlowInstance)
resolveDelivery identity delivery = send . ResolveDelivery identity delivery

startPreparedInstance :: FlowStore :> es => Maybe FlowInstanceId -> Text -> PreparedFlow -> Eff es (Either FlowStoreProblem FlowInstance)
startPreparedInstance parent key = send . StartPreparedInstance parent (Just key)
readExecutionBundle :: FlowStore :> es => FlowBundleId -> Eff es (Either [Diagnostic] FlowBundle)
readExecutionBundle = send . ReadExecutionBundle

clearInstances :: FlowStore :> es => [FlowInstanceId] -> Eff es (Either FlowStoreProblem [FlowInstanceId])
clearInstances = send . ClearInstances

linkAttempt :: FlowStore :> es => FlowInstanceId -> RecipeRunId -> Eff es (Either FlowStoreProblem FlowInstance)
linkAttempt identity = send . LinkAttempt identity

blockAttempt :: FlowStore :> es => FlowInstanceId -> [Diagnostic] -> Eff es (Either FlowStoreProblem FlowInstance)
blockAttempt identity = send . BlockAttempt identity
retryInstance :: FlowStore :> es => FlowInstanceId -> Eff es (Either FlowStoreProblem FlowInstance)
retryInstance = send . RetryInstance

startNewPreparedInstance :: FlowStore :> es => Maybe FlowInstanceId -> PreparedFlow -> Eff es (Either FlowStoreProblem FlowInstance)
startNewPreparedInstance parent = send . StartPreparedInstance parent Nothing
queueNewDelivery :: FlowStore :> es => FlowInstanceId -> Text -> ReplyOrigin -> Value -> Eff es (Either FlowStoreProblem FlowDelivery)
queueNewDelivery identity wait origin = send . QueueDelivery identity Nothing wait origin

readBundleDescription :: FlowStore :> es => FlowBundleId -> Eff es (Either [Diagnostic] FlowBundle)
readBundleDescription = send . ReadBundleDescription

readDescendant :: FlowStore :> es => FlowInstanceId -> FlowInstanceId -> Eff es (Either FlowStoreProblem FlowInstance)
readDescendant caller = send . ReadDescendant caller
cancelDescendant :: FlowStore :> es => FlowInstanceId -> FlowInstanceId -> CancelScope -> Eff es (Either FlowStoreProblem FlowInstance)
cancelDescendant caller target = send . CancelDescendant caller target
