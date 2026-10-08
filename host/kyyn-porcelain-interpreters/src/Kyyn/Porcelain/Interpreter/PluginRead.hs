{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (contractId, contractShape, rootType)
import Kyyn.Domain.Blob (ResolvedBlob(..), blobReferences)
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..), EvidenceProblem(..), evidenceProblemDiagnostic, CurrentEvidence(..), EvidenceSnapshotRef(..), Evidence(..), EvidencePayload(..))
import Kyyn.Domain.Diagnostic (Diagnostic(..), errorDiagnostic)
import Kyyn.Domain.Plugin (pluginNameText)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.BlobStorage (BlobStorage, blobPathAt)
import Kyyn.Types.Plugin (FetchError(..))
import Kyyn.Porcelain.Capability.PluginRead
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedMethod(..))
import qualified Kyyn.Porcelain.Capability.EvidenceStore as Store
import Kyyn.Porcelain.Protocol.PluginBroker (executeCapturedRead)

runPluginRead :: (BlobStorage :> es, Store.EvidenceStore :> es, GuestExecution :> es, DhallHandling :> es, Failure :> es)
  => Eff (PluginRead : es) a -> Eff es a
runPluginRead = interpret $ \_ -> \case
  LoadCapturedInput instanceRef@(ConnectorInstanceRef plugin name) producer payload -> runExceptT $ do
    let problem failure = case evidenceProblemDiagnostic failure of
          Diagnostic severity code message location -> [Diagnostic severity code
            (Text.pack (pluginNameText plugin ++ "/" ++ name ++ ": ") <> message) location]
    loaded <- ExceptT (fmap (either (Left . problem) Right) (Store.loadCurrentEvidence instanceRef producer payload))
    maybe (throwE (problem NotFetched)) pure loaded
  ExecuteCapturedMethod payload current (PreparedMethod _ _ input output program) value -> runExceptT $ do
    _ <- ExceptT (encodeValue (contractShape input) value)
    result <- ExceptT (executeCapturedRead program (CheckedValue (contractId input) value) payload current output)
    pure (fmap (CheckedValue (contractId output)) result)
  ResolveCapturedBlobs contexts contract value -> runExceptT $ do
    let parse = either (throwE . pure . errorDiagnostic "blob.reference") pure
    refs <- parse (blobReferences (rootType contract) value)
    if null refs then pure [] else do
      origins <- fmap concat $ mapM (\(payload,CurrentEvidence (EvidenceSnapshotRef instanceRef _ _) items _) -> do
        known <- parse (concat <$> traverse (blobReferences (rootType payload))
          [v | (_,Evidence _ _ (Available (CheckedValue _ v))) <- items])
        pure [(ref,instanceRef) | ref <- known]) contexts
      mapM (\ref -> case lookup ref origins of
        Nothing -> throwE [errorDiagnostic "blob.unreachable" "Result contains a blob outside the captured evidence."]
        Just instanceRef -> do
          path <- ExceptT (fmap (either (\(FetchError message) -> Left [errorDiagnostic "blob.unavailable" (Text.unpack message)]) Right)
            (blobPathAt instanceRef ref))
          pure (ResolvedBlob ref path)) refs
