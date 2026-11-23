{-# LANGUAGE OverloadedRecordDot #-}
module Kyyn.Porcelain.Interpreter.FlowControl (answerFlowControl) where

import Control.Monad (unless, void)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Data.Aeson (Value(..), object, toJSON)
import Agentic.Aeson (fromAeson, toAeson)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Contract (descriptionOf)
import Kyyn.Domain.FlowClosure (FlowDeclaration(..))
import Kyyn.Domain.FlowInstance
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeEntry)
import Kyyn.Plumbing.Protocol.PluginMessages (parseResult, success, failure)
import Kyyn.Plumbing.Protocol.Tool (FlowControlCall(..))
import Kyyn.Porcelain.Capability.Flow (flowProblem)
import Kyyn.Porcelain.Capability.FlowPreparation (FlowBundle(..), PreparedFlow(..), PreparedFlowEntry(..))
import Kyyn.Porcelain.Capability.FlowStore
import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Kyyn.Types.Guest (InteractiveInvocation(..))
import qualified Kyyn.Types.FlowStatus as View
import Kyyn.Types.Wire (parseWire)

-- Parent identity comes from the worker's locked instance, never a submitted ID.
answerFlowControl :: (FlowStore :> es, GuestExecution :> es, Failure :> es)
  => FlowInstanceId -> FlowBundle -> FlowControlCall -> Eff es Value
answerFlowControl parent bundle operation = do
  result <- runExceptT $ do
    current <- lift (readInstance parent) >>= maybe (throwE "Parent instance is no longer available") pure
    (parentBundle,parentRecipe) <- case current.launch.owner of
      Hosted identity (RecipeId name) -> pure (identity,name)
      External -> throwE "Parent has no captured execution"
    let checkedStore action = lift action >>= either (throwE . Text.unpack . (.message) . flowProblem) pure
        definition recipe = case [entry | entry <- bundle.closure, entry.declaration.recipe == recipe] of
          [entry] -> pure entry
          _ -> throwE "Child is outside the captured flow definitions"
        check recipe label expected actual = unless (expected == descriptionOf actual)
          (throwE ("Parent recipe " ++ Text.unpack parentRecipe ++ " cannot control child recipe " ++
            Text.unpack recipe ++ ": " ++ label ++ " contract mismatch"))
        target identity expected = do
          selectedId <- either throwE pure (flowInstanceId identity)
          selected <- checkedStore (readDescendant parent selectedId)
          recipe <- case selected.launch.owner of
            Hosted identity' recipe | identity' == parentBundle -> pure recipe
            _ -> throwE "Child does not share the parent's captured execution bundle"
          entry <- definition recipe
          let RecipeId name = recipe
          check name "output" expected entry.outputContract
          pure selected
    case operation of
      StartChildCall namespace key recipe@(RecipeId childRecipe) inputContract outputContract input -> do
        unless (namespace == flowInstanceIdText parent && not (Text.null key))
          (throwE "Child start key does not belong to this parent")
        child <- definition recipe
        check childRecipe "input" inputContract child.inputContract
        check childRecipe "output" outputContract child.outputContract
        response <- lift (executeEntry child.entry (toJSON (ValidateFlowInput input)))
        canonical <- either throwE pure (parseWire response >>= parseResult) >>= either throwE pure
        started <- checkedStore (startPreparedInstance (Just parent) key (PreparedFlow recipe canonical bundle))
        pure (String (flowInstanceIdText started.instanceId))
      InspectChildCall identity expected -> do
        selected <- target identity expected
        pure (toAeson (View.encodeStatus fromAeson (status selected)))
      CancelChildCall identity expected descendants -> do
        selected <- target identity expected
        -- Recheck downward authority atomically with the cancellation request.
        void (checkedStore (cancelDescendant parent selected.instanceId (if descendants then FlowAndDescendants else ThisFlow)))
        pure (object [])
  pure (either failure success result)

status :: FlowInstance -> View.FlowStatus Value
status selected = View.FlowStatus (case selected.status of
  Runnable -> View.Runnable
  Running -> View.Running
  Waiting -> View.Waiting
  Finished outcome -> View.Finished (case outcome of
    Completed value -> View.Completed value
    Failed problems -> View.Failed problems
    Cancelled -> View.Cancelled))
  [wait.waitId | wait <- selected.waits, wait.waitStatus == Open]
