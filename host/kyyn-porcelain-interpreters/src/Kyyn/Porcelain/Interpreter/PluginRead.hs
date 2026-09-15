{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..), EvidenceProblem(..), evidenceProblemDiagnostic)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Plugin (pluginNameText)
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
runPluginRead = interpret $ \_ -> \case
  LoadCapturedInput instanceRef@(ConnectorInstanceRef plugin name) producer payload -> runExceptT $ do
    let problem failure = case evidenceProblemDiagnostic failure of
          Diagnostic severity code message location -> [Diagnostic severity code
            (pluginNameText plugin ++ "/" ++ name ++ ": " ++ message) location]
    loaded <- ExceptT (fmap (either (Left . problem) Right) (Store.loadCurrentEvidence instanceRef producer payload))
    maybe (throwE (problem NotFetched)) pure loaded
  ExecuteCapturedMethod current (PreparedMethod _ _ input output program) value -> runExceptT $ do
    _ <- ExceptT (encodeValue (contractShape input) value)
    result <- ExceptT (executeCapturedRead program (CheckedValue (contractId input) value) current output)
    pure (fmap (CheckedValue (contractId output)) result)
