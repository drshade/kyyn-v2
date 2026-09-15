{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvidenceStore
  ( EvidenceStore(..), evidenceHead, publishFetch, loadCurrentEvidence
  , readFetchHistory, listEvidenceChanges, clearEvidence
  ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Value (CheckedValue)

data EvidenceStore :: Effect where
  EvidenceHead :: ConnectorInstanceRef -> EvidenceStore m (Either EvidenceProblem (Maybe FetchId))
  PublishFetch :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe FetchId
    -> [EvidenceChange CheckedValue] -> EvidenceStore m (Either EvidenceProblem EvidenceSnapshotRef)
  LoadCurrentEvidence :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
    -> EvidenceStore m (Either EvidenceProblem (Maybe CurrentEvidence))
  ReadFetchHistory :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
    -> EvidenceStore m (Either EvidenceProblem (EvidenceSnapshotRef, [FetchSummary]))
  ListEvidenceChanges :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe FetchId
    -> EvidenceStore m (Either EvidenceProblem (EvidenceSnapshotRef, [EvidenceChangeSummary]))
  ClearEvidence :: ConnectorInstanceRef -> EvidenceStore m ()

type instance DispatchOf EvidenceStore = Dynamic

evidenceHead :: EvidenceStore :> es => ConnectorInstanceRef -> Eff es (Either EvidenceProblem (Maybe FetchId))
evidenceHead = send . EvidenceHead
publishFetch :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Maybe FetchId -> [EvidenceChange CheckedValue] -> Eff es (Either EvidenceProblem EvidenceSnapshotRef)
publishFetch instanceRef producer contract base = send . PublishFetch instanceRef producer contract base
loadCurrentEvidence :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Eff es (Either EvidenceProblem (Maybe CurrentEvidence))
loadCurrentEvidence instanceRef producer = send . LoadCurrentEvidence instanceRef producer
readFetchHistory :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Eff es (Either EvidenceProblem (EvidenceSnapshotRef, [FetchSummary]))
readFetchHistory instanceRef producer = send . ReadFetchHistory instanceRef producer
listEvidenceChanges :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe FetchId
  -> Eff es (Either EvidenceProblem (EvidenceSnapshotRef, [EvidenceChangeSummary]))
listEvidenceChanges instanceRef producer contract = send . ListEvidenceChanges instanceRef producer contract
clearEvidence :: EvidenceStore :> es => ConnectorInstanceRef -> Eff es ()
clearEvidence = send . ClearEvidence
