{-# LANGUAGE OverloadedRecordDot #-}
module Kyyn.Porcelain.Interpreter.FlowControl (answerFlowControl) where

import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Data.Aeson (Value(..), toJSON)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Contract (descriptionOf)
import Kyyn.Domain.FlowClosure (FlowDeclaration(..))
import Kyyn.Domain.FlowInstance (FlowInstanceId, flowInstanceIdText, FlowInstance(..))
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeEntry)
import Kyyn.Plumbing.Protocol.PluginMessages (parseResult, success, failure)
import Kyyn.Plumbing.Protocol.Tool (FlowControlCall(..))
import Kyyn.Porcelain.Capability.Flow (flowProblem)
import Kyyn.Porcelain.Capability.FlowPreparation (FlowBundle(..), PreparedFlow(..), PreparedFlowEntry(..))
import Kyyn.Porcelain.Capability.FlowStore (FlowStore, startPreparedInstance)
import Kyyn.Types.Guest (InteractiveInvocation(..))
import Kyyn.Types.Wire (parseWire)

-- The worker supplies this context from its locked instance, never from a
-- submitted parent ID. The store rechecks declared-child and subtree authority
-- in the same transaction that publishes the child.
answerFlowControl :: (FlowStore :> es, GuestExecution :> es, Failure :> es)
  => FlowInstanceId -> FlowBundle -> FlowControlCall -> Eff es Value
answerFlowControl parent bundle (StartChildCall namespace key recipe inputContract outputContract input) = do
  result <- runExceptT $ do
    if namespace /= flowInstanceIdText parent || Text.null key
      then throwE "Child start key does not belong to this parent" else pure ()
    child <- case [entry | entry <- bundle.closure, entry.declaration.recipe == recipe] of
      [entry] -> pure entry
      _ -> throwE "Child is outside the captured flow definitions"
    let check label expected actual = if expected == descriptionOf actual then pure () else
          throwE ("Child " ++ label ++ " contract mismatch: requested " ++ show expected ++ "; captured " ++ show (descriptionOf actual))
    check "input" inputContract child.inputContract
    check "output" outputContract child.outputContract
    response <- lift (executeEntry child.entry (toJSON (ValidateFlowInput input)))
    canonical <- either throwE pure (parseWire response >>= parseResult) >>= either throwE pure
    started <- lift (startPreparedInstance (Just parent) key (PreparedFlow recipe canonical bundle))
    either (throwE . Text.unpack . (.message) . flowProblem) (pure . String . flowInstanceIdText . (.instanceId)) started
  pure (either failure success result)
