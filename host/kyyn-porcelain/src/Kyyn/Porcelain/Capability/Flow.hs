{-# LANGUAGE DataKinds, GADTs, TypeFamilies, OverloadedStrings #-}
module Kyyn.Porcelain.Capability.Flow (Flow(..), startFlowAt, flowProblem) where

import Data.Text (Text)
import qualified Data.Text as Text
import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FlowInstance (FlowInstance, FlowStoreProblem(..))
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Recipe (RecipeId)

data Flow :: Effect where
  StartFlowAt :: KnowledgeBase -> GitRevision -> RecipeId -> Text -> Maybe Text
    -> Flow m (Either [Diagnostic] FlowInstance)
type instance DispatchOf Flow = Dynamic

startFlowAt :: Flow :> es => KnowledgeBase -> GitRevision -> RecipeId -> Text -> Maybe Text
  -> Eff es (Either [Diagnostic] FlowInstance)
startFlowAt kb revision recipe key = send . StartFlowAt kb revision recipe key

flowProblem :: FlowStoreProblem -> Diagnostic
flowProblem problem = errorDiagnostic "flow.operation" $ case problem of
  MissingInstance -> "The flow instance does not exist or has been cleared"
  AlreadyFinished -> "The flow instance has already finished"
  CancelledAncestor -> "An ancestor has cancelled this flow's subtree"
  StartConflict -> "This caller key already names a different start request"
  NotHosted -> "This instance is owned by an external harness"
  ExecutionBlocked -> "This flow is blocked; inspect its diagnostics and explicitly retry after resolving them"
  InvalidTransition message -> Text.unpack message
