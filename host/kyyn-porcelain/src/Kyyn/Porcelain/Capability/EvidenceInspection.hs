{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvidenceInspection
  ( EvidenceInspection(..), currentEvidence, readCurrentEvidence ) where

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
    -> EvidenceInspection m (Either [Diagnostic] (EvidenceSnapshotRef, FetchSummary, Maybe (Evidence CheckedValue)))
type instance DispatchOf EvidenceInspection = Dynamic

currentEvidence :: EvidenceInspection :> es
  => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Eff es (Either [Diagnostic] EvidenceCapture)
currentEvidence instanceRef producer = send . ListCurrentEvidence instanceRef producer

readCurrentEvidence :: EvidenceInspection :> es
  => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> EvidenceId
  -> Eff es (Either [Diagnostic] (EvidenceSnapshotRef, FetchSummary, Maybe (Evidence CheckedValue)))
readCurrentEvidence instanceRef producer payload = send . ReadCurrentEvidence instanceRef producer payload
