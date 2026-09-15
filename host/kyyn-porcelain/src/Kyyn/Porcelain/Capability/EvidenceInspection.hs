{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvidenceInspection
  ( EvidenceInspection(..), fetchHistory, evidenceChanges ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evidence

data EvidenceInspection :: Effect where
  FetchHistory :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
    -> EvidenceInspection m (Either [Diagnostic] (EvidenceSnapshotRef, [FetchSummary]))
  EvidenceChanges :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe FetchId
    -> EvidenceInspection m (Either [Diagnostic] (EvidenceSnapshotRef, [EvidenceChangeSummary]))
type instance DispatchOf EvidenceInspection = Dynamic

fetchHistory :: EvidenceInspection :> es
  => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Eff es (Either [Diagnostic] (EvidenceSnapshotRef, [FetchSummary]))
fetchHistory instanceRef producer payload = send (FetchHistory instanceRef producer payload)

evidenceChanges :: EvidenceInspection :> es
  => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe FetchId
  -> Eff es (Either [Diagnostic] (EvidenceSnapshotRef, [EvidenceChangeSummary]))
evidenceChanges instanceRef producer payload = send . EvidenceChanges instanceRef producer payload
