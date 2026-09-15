{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Evidence (EvidenceProblem(..), evidenceProblemDiagnostic)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Porcelain.Capability.PluginRead
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedMethod(..))
import qualified Kyyn.Porcelain.Capability.EvidenceStore as Store
import Kyyn.Porcelain.Protocol.PluginBroker (executeCapturedRead)

runPluginRead :: (Store.EvidenceStore :> es, GuestExecution :> es, DhallHandling :> es, Failure :> es)
  => Eff (PluginRead : es) a -> Eff es a
runPluginRead = interpret $ \_ (CallCapturedMethod instanceRef producer payload
    (PreparedMethod _ _ input output program) arguments@(CheckedValue identity value)) -> runExceptT $ do
  unless (identity == contractId input)
    (throwE [errorDiagnostic "plugin.input-contract" "Input does not match the selected method's contract"])
  _ <- ExceptT (encodeValue (contractShape input) value)
  loaded <- ExceptT (fmap (either (Left . pure . evidenceProblemDiagnostic) Right)
    (Store.loadCurrentEvidence instanceRef producer payload))
  current <- maybe (throwE [evidenceProblemDiagnostic NotFetched]) pure loaded
  result <- ExceptT (executeCapturedRead program arguments current output)
  pure (CheckedValue (contractId output) result)
