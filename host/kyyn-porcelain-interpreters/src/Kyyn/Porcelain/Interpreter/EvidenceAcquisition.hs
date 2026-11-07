{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.EvidenceAcquisition (runEvidenceAcquisition) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson ((.:))
import Kyyn.Types.Guest (AcquisitionContext(..))
import Data.Aeson.Types (parseEither, withObject)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.DataType (Shape(..))
import Kyyn.Domain.Path (DirectoryScope)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Domain.EvidenceIndex (EvidenceSelection(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Domain.Value (CheckedValue(..))
import qualified Kyyn.Porcelain.Capability.EvidenceStore as Store
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.FileAcquisition (FileAcquisition)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Porcelain.Protocol.PluginHost (executeAcquisition)
import Kyyn.Plumbing.Capability.HttpTransport (HttpTransport)
import Kyyn.Plumbing.Capability.BlobStorage (BlobStorage, withBlobDownloads)
import Kyyn.Plumbing.Capability.ConcurrentExecution (ConcurrentExecution)
import Kyyn.Plumbing.Capability.ContentDigest (ContentDigest)
import Kyyn.Plumbing.Capability.SecretStore (SecretStore)
import Kyyn.Plumbing.Capability.PluginInteraction (Waiting)
import Kyyn.Plumbing.Protocol.PluginMessages (changesShape, parseChanges)
import Kyyn.Porcelain.Capability.EvidenceAcquisition

runEvidenceAcquisition :: (ConcurrentExecution :> es, ContentDigest :> es, BlobStorage :> es, Store.EvidenceStore :> es, GuestExecution :> es, FileAcquisition :> es, HttpTransport :> es, SecretStore :> es, Waiting :> es,
    DhallHandling :> es, Failure :> es) => DirectoryScope -> Eff (EvidenceAcquisition : es) a -> Eff es a
runEvidenceAcquisition baseDirectory = interpret $ \_ (FetchEvidence selection@(EvidenceSelection instanceRef _ _) payload program config optionsContract positionContract reportContract mode supplied) -> runExceptT $ do
  let CheckedValue _ configValue = config
  (decodedOptions,optionsText) <- case (optionsContract,supplied) of
    (Nothing,Nothing) -> pure (Nothing,Nothing)
    (Nothing,Just _) -> throwE [errorDiagnostic "plugin.fetch-options-unsupported" "This connector does not accept fetch options."]
    (Just options,input) -> do
      decoded <- traverse (ExceptT . decodeValue (contractShape options) . Text.pack) input
      rendered <- traverse (ExceptT . encodeValue (contractShape options)) decoded
      pure (decoded,Text.unpack <$> rendered)
  Store.FetchBaseline startedAt base prior position <- ExceptT
    (fmap (either (Left . problem) Right) (Store.beginFetch selection payload positionContract))
  let context = case positionContract of
        Nothing -> Nothing
        Just _ -> Just (AcquisitionContext (Text.pack startedAt)
          ((\(CheckedValue _ value) -> value) <$> case mode of ContinueSync -> position; RestartSync -> Nothing))
  ExceptT $ withBlobDownloads instanceRef (Store.discardFetchBlobs instanceRef base) $ runExceptT $ do
    result <- ExceptT (executeAcquisition baseDirectory instanceRef program configValue decodedOptions context prior)
    (delta,savedPosition,savedReport) <- case (positionContract,reportContract) of
      (Nothing,Nothing) -> do
        _ <- ExceptT (encodeValue (changesShape (contractShape payload)) result)
        pure (result,Nothing,Nothing)
      (Just contract,Just report) -> do
        _ <- ExceptT (encodeValue (Record [("changes",changesShape (contractShape payload)),
          ("position",contractShape contract),("report",contractShape report)]) result)
        (changes,next,reported) <- either (throwE . pure . errorDiagnostic "plugin.invalid-delta") pure
          (parseEither (withObject "fetch result" $ \fields -> (,,) <$> fields .: "changes" <*> fields .: "position" <*> fields .: "report") result)
        pure (changes,Just (contract,CheckedValue (contractId contract) next),Just (FetchReport report (CheckedValue (contractId report) reported)))
      _ -> throwE [errorDiagnostic "plugin.report-contract" "Position and report contracts must occur together"]
    changes <- either (throwE . pure . errorDiagnostic "plugin.invalid-delta") pure (parseChanges payload delta)
    ExceptT (fmap (either (Left . problem) Right)
      (Store.publishFetch selection payload base optionsText changes savedPosition savedReport))

problem :: EvidenceProblem -> [Diagnostic]
problem failure = [evidenceProblemDiagnostic failure]
