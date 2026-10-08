{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.EvidenceAcquisition (runEvidenceAcquisition) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (object, (.=), (.:))
import Data.Aeson.Types (parseEither, withObject)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.DataType (Shape(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Domain.Value (CheckedValue(..))
import qualified Kyyn.Porcelain.Capability.EvidenceStore as Store
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.FileAcquisition (FileAcquisition)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Porcelain.Protocol.PluginHost (executeAcquisition)
import Kyyn.Plumbing.Capability.HttpTransport (HttpTransport)
import Kyyn.Plumbing.Capability.BlobStorage (BlobStorage, withBlobDownloads)
import Kyyn.Plumbing.Capability.ContentDigest (ContentDigest)
import Kyyn.Plumbing.Capability.SecretStore (SecretStore)
import Kyyn.Plumbing.Capability.PluginInteraction (Waiting)
import Kyyn.Plumbing.Protocol.PluginMessages (changesShape, parseChanges)
import Kyyn.Porcelain.Capability.EvidenceAcquisition

runEvidenceAcquisition :: (ContentDigest :> es, BlobStorage :> es, Store.EvidenceStore :> es, GuestExecution :> es, FileAcquisition :> es, HttpTransport :> es, SecretStore :> es, Waiting :> es,
    DhallHandling :> es, Failure :> es) => Eff (EvidenceAcquisition : es) a -> Eff es a
runEvidenceAcquisition = interpret $ \_ (FetchEvidence instanceRef package payload program config optionsContract positionContract mode supplied) -> runExceptT $ do
  let CheckedValue _ configValue = config
  (arguments,optionsText) <- case (optionsContract,supplied) of
    (Nothing,Nothing) -> pure (configValue,Nothing)
    (Nothing,Just _) -> throwE [errorDiagnostic "plugin.fetch-options-unsupported" "This connector does not accept fetch options."]
    (Just options,input) -> do
      decoded <- traverse (ExceptT . decodeValue (contractShape options) . Text.pack) input
      rendered <- traverse (ExceptT . encodeValue (contractShape options)) decoded
      let optional = maybe (object ["tag" .= ("None" :: String)])
            (\v -> object ["tag" .= ("Some" :: String),"value" .= v]) decoded
      pure (object ["config" .= configValue,"options" .= optional],Text.unpack <$> rendered)
  let producer = EvidenceProducer package (contractId payload)
  Store.FetchBaseline startedAt base prior position <- ExceptT
    (fmap (either (Left . problem) Right) (Store.beginFetch instanceRef producer payload positionContract))
  let input = case positionContract of
        Nothing -> arguments
        Just _ -> object ["input" .= arguments,"startedAt" .= startedAt,"priorPosition" .=
          maybe (object ["tag" .= ("None" :: String)])
            (\(CheckedValue _ value) -> object ["tag" .= ("Some" :: String),"value" .= value])
            (case mode of ContinueSync -> position; RestartSync -> Nothing)]
  ExceptT $ withBlobDownloads instanceRef (Store.discardFetchBlobs instanceRef base) $ runExceptT $ do
    result <- ExceptT (executeAcquisition instanceRef program input prior)
    (delta,savedPosition) <- case positionContract of
      Nothing -> do
        _ <- ExceptT (encodeValue (changesShape (contractShape payload)) result)
        pure (result,Nothing)
      Just contract -> do
        _ <- ExceptT (encodeValue (Record [("changes",changesShape (contractShape payload)),
          ("position",contractShape contract)]) result)
        (changes,next) <- either (throwE . pure . errorDiagnostic "plugin.invalid-delta") pure
          (parseEither (withObject "fetch result" $ \fields -> (,) <$> fields .: "changes" <*> fields .: "position") result)
        pure (changes,Just (contract,CheckedValue (contractId contract) next))
    changes <- either (throwE . pure . errorDiagnostic "plugin.invalid-delta") pure (parseChanges payload delta)
    ExceptT (fmap (either (Left . problem) Right)
      (Store.publishFetchWithPosition instanceRef producer payload base optionsText changes savedPosition))

problem :: EvidenceProblem -> [Diagnostic]
problem failure = [evidenceProblemDiagnostic failure]
