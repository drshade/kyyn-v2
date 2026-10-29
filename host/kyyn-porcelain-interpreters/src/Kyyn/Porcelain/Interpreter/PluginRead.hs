{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Control.Monad (unless)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..), EvidenceProblem(..), evidenceProblemDiagnostic)
import Kyyn.Domain.EvidenceIndex (EvidenceSelection(..), EvidenceIndex(..))
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Plugin (pluginNameText)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.BlobStorage (BlobStorage)
import Kyyn.Porcelain.Capability.PluginRead
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedMethod(..))
import qualified Kyyn.Porcelain.Capability.EvidenceStore as Store
import Kyyn.Porcelain.Protocol.CapturedBlobs (resolveBlobs)
import Kyyn.Porcelain.Protocol.PluginBroker (executeCapturedRead)

runPluginRead :: (BlobStorage :> es, Store.EvidenceStore :> es, GuestExecution :> es, DhallHandling :> es, Failure :> es)
  => Eff (PluginRead : es) a -> Eff es a
runPluginRead = interpret $ \_ -> \case
  LoadCapturedInput selection@(EvidenceSelection (ConnectorInstanceRef plugin name) _ _) expected -> runExceptT $ do
    let problem failure = case evidenceProblemDiagnostic failure of
          Diagnostic severity code message location -> [Diagnostic severity code
            (Text.pack (pluginNameText plugin ++ "/" ++ name ++ ": ") <> message) location]
    loaded <- ExceptT (fmap (either (Left . problem) Right) (Store.openCurrentEvidence selection))
    index@(EvidenceIndex _ _ actual _) <- maybe (throwE (problem NotFetched)) pure loaded
    unless (contractId actual == contractId expected) (throwE (problem ProducerContractChanged))
    pure index
  ExecuteCapturedMethod current (PreparedMethod _ _ input output program) value -> runExceptT $ do
    _ <- ExceptT (encodeValue (contractShape input) value)
    result <- ExceptT (executeCapturedRead program (CheckedValue (contractId input) value) current output)
    pure (fmap (CheckedValue (contractId output)) result)
  ResolveCapturedBlobs contexts contract value -> resolveBlobs contexts contract value
