{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.EvidenceAcquisition (runEvidenceAcquisition) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import qualified Kyyn.Plumbing.Capability.EvidenceStore as Store
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.FileAcquisition (FileAcquisition)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Protocol.PluginBroker (executeAcquisition)
import Kyyn.Plumbing.Protocol.PluginMessages (changesShape, parseChanges)
import Kyyn.Porcelain.Capability.EvidenceAcquisition

runEvidenceAcquisition :: (Store.EvidenceStore :> es, GuestExecution :> es, FileAcquisition :> es,
    DhallHandling :> es, Failure :> es) => Eff (EvidenceAcquisition : es) a -> Eff es a
runEvidenceAcquisition = interpret $ \_ (FetchEvidence instanceRef package payload program config) -> runExceptT $ do
  base <- ExceptT (fmap (either (Left . problem) Right) (Store.evidenceHead instanceRef))
  let producer = EvidenceProducer package (contractId payload)
  prior <- case base of
    Nothing -> pure Nothing
    Just identity -> do
      selected <- ExceptT (Right <$> Store.selectEvidence instanceRef producer (AtFetch identity))
      case selected of
        Left ProducerContractChanged -> pure Nothing
        Left failure -> throwE (problem failure)
        Right snapshot -> pure (Just snapshot)
  result <- ExceptT (executeAcquisition program config payload prior)
  _ <- ExceptT (encodeValue (changesShape (contractShape payload)) result)
  changes <- either (throwE . pure . errorDiagnostic "plugin.invalid-delta") pure (parseChanges payload result)
  ExceptT (fmap (either (Left . problem) Right) (Store.publishFetch instanceRef producer payload base changes))

problem :: EvidenceProblem -> [Diagnostic]
problem failure = [evidenceProblemDiagnostic failure]
