{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvidenceInspection
  ( EvidenceInspection(..), currentEvidence, readCurrentEvidence, fetchHistory, evidenceChanges ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Value (CheckedValue)

data EvidenceInspection :: Effect where
  ListCurrentEvidence :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
    -> EvidenceInspection m (Either [Diagnostic] EvidenceCapture)
  ReadCurrentEvidence :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> EvidenceId
    -> EvidenceInspection m (Either [Diagnostic] (EvidenceSnapshotRef, Maybe (Evidence CheckedValue)))
  FetchHistory :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
    -> EvidenceInspection m (Either [Diagnostic] (EvidenceSnapshotRef, [FetchSummary]))
  EvidenceChanges :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe FetchId
    -> EvidenceInspection m (Either [Diagnostic] (EvidenceSnapshotRef, [EvidenceChangeSummary]))
type instance DispatchOf EvidenceInspection = Dynamic

currentEvidence :: EvidenceInspection :> es
  => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Eff es (Either [Diagnostic] EvidenceCapture)
currentEvidence instanceRef producer = send . ListCurrentEvidence instanceRef producer

readCurrentEvidence :: EvidenceInspection :> es
  => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> EvidenceId
  -> Eff es (Either [Diagnostic] (EvidenceSnapshotRef, Maybe (Evidence CheckedValue)))
readCurrentEvidence instanceRef producer payload = send . ReadCurrentEvidence instanceRef producer payload

fetchHistory :: EvidenceInspection :> es
  => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Eff es (Either [Diagnostic] (EvidenceSnapshotRef, [FetchSummary]))
fetchHistory instanceRef producer payload = send (FetchHistory instanceRef producer payload)

evidenceChanges :: EvidenceInspection :> es
  => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe FetchId
  -> Eff es (Either [Diagnostic] (EvidenceSnapshotRef, [EvidenceChangeSummary]))
evidenceChanges instanceRef producer payload = send . EvidenceChanges instanceRef producer payload
