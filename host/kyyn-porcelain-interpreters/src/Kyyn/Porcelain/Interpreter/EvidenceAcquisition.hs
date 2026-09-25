{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.EvidenceAcquisition (runEvidenceAcquisition) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (object, (.=))
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Domain.Value (CheckedValue(..))
import qualified Kyyn.Porcelain.Capability.EvidenceStore as Store
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.FileAcquisition (FileAcquisition)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Porcelain.Protocol.PluginBroker (executeAcquisition)
import Kyyn.Plumbing.Protocol.PluginMessages (changesShape, parseChanges)
import Kyyn.Porcelain.Capability.EvidenceAcquisition

runEvidenceAcquisition :: (Store.EvidenceStore :> es, GuestExecution :> es, FileAcquisition :> es,
    DhallHandling :> es, Failure :> es) => Eff (EvidenceAcquisition : es) a -> Eff es a
runEvidenceAcquisition = interpret $ \_ (FetchEvidence instanceRef package payload program config optionsContract supplied) -> runExceptT $ do
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
  observedHead <- ExceptT (fmap (either (Left . problem) Right) (Store.evidenceHead instanceRef))
  loaded <- ExceptT (Right <$> Store.loadCurrentEvidence instanceRef producer payload)
  (base,prior) <- case loaded of
    Right Nothing -> pure (Nothing,Nothing)
    Right current@(Just (CurrentEvidence (EvidenceSnapshotRef _ _ identity) _)) -> pure (Just identity,current)
    Left ProducerContractChanged -> pure (observedHead,Nothing)
    Left failure -> throwE (problem failure)
  result <- ExceptT (executeAcquisition program arguments prior)
  _ <- ExceptT (encodeValue (changesShape (contractShape payload)) result)
  changes <- either (throwE . pure . errorDiagnostic "plugin.invalid-delta") pure (parseChanges payload result)
  ExceptT (fmap (either (Left . problem) Right) (Store.publishFetch instanceRef producer payload base optionsText changes))

problem :: EvidenceProblem -> [Diagnostic]
problem failure = [evidenceProblemDiagnostic failure]
