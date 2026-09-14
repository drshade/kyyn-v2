{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvidenceAcquisition (EvidenceAcquisition(..), fetchEvidence) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evidence (ConnectorInstanceRef, EvidenceSnapshotRef)
import Kyyn.Domain.Plugin (PackageIdentity)
import Kyyn.Domain.Value (CheckedValue)

data EvidenceAcquisition :: Effect where
  FetchEvidence :: ConnectorInstanceRef -> PackageIdentity -> CheckedContract -> CompiledProgram -> CheckedValue
    -> EvidenceAcquisition m (Either [Diagnostic] EvidenceSnapshotRef)

type instance DispatchOf EvidenceAcquisition = Dynamic

fetchEvidence :: EvidenceAcquisition :> es
  => ConnectorInstanceRef -> PackageIdentity -> CheckedContract -> CompiledProgram -> CheckedValue
  -> Eff es (Either [Diagnostic] EvidenceSnapshotRef)
fetchEvidence instanceRef package payload program config = send (FetchEvidence instanceRef package payload program config)
