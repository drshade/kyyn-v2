{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.EvidenceAcquisition (runEvidenceAcquisition) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import qualified Kyyn.Porcelain.Capability.EvidenceStore as Store
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.FileAcquisition (FileAcquisition)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Porcelain.Protocol.PluginBroker (executeAcquisition)
import Kyyn.Plumbing.Protocol.PluginMessages (changesShape, parseChanges)
import Kyyn.Porcelain.Capability.EvidenceAcquisition

runEvidenceAcquisition :: (Store.EvidenceStore :> es, GuestExecution :> es, FileAcquisition :> es,
    DhallHandling :> es, Failure :> es) => Eff (EvidenceAcquisition : es) a -> Eff es a
runEvidenceAcquisition = interpret $ \_ (FetchEvidence instanceRef package payload program config) -> runExceptT $ do
  let producer = EvidenceProducer package (contractId payload)
  observedHead <- ExceptT (fmap (either (Left . problem) Right) (Store.evidenceHead instanceRef))
  loaded <- ExceptT (Right <$> Store.loadCurrentEvidence instanceRef producer payload)
  (base,prior) <- case loaded of
    Right Nothing -> pure (Nothing,Nothing)
    Right current@(Just (CurrentEvidence (EvidenceSnapshotRef _ _ identity) _)) -> pure (Just identity,current)
    Left ProducerContractChanged -> pure (observedHead,Nothing)
    Left failure -> throwE (problem failure)
  result <- ExceptT (executeAcquisition program config prior)
  _ <- ExceptT (encodeValue (changesShape (contractShape payload)) result)
  changes <- either (throwE . pure . errorDiagnostic "plugin.invalid-delta") pure (parseChanges payload result)
  ExceptT (fmap (either (Left . problem) Right) (Store.publishFetch instanceRef producer payload base changes))

problem :: EvidenceProblem -> [Diagnostic]
problem failure = [evidenceProblemDiagnostic failure]
