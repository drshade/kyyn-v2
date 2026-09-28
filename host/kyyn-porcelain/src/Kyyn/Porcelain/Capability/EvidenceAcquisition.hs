{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvidenceAcquisition (EvidenceAcquisition(..), fetchEvidence) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evidence (ConnectorInstanceRef, EvidenceSnapshotRef)
import Kyyn.Domain.Plugin (PackageIdentity, AcquisitionContext)
import Kyyn.Domain.Value (CheckedValue)

data EvidenceAcquisition :: Effect where
  FetchEvidence :: AcquisitionContext -> ConnectorInstanceRef -> PackageIdentity -> CheckedContract -> CompiledProgram -> CheckedValue
    -> Maybe CheckedContract -> Maybe String
    -> EvidenceAcquisition m (Either [Diagnostic] EvidenceSnapshotRef)

type instance DispatchOf EvidenceAcquisition = Dynamic

fetchEvidence :: EvidenceAcquisition :> es
  => AcquisitionContext -> ConnectorInstanceRef -> PackageIdentity -> CheckedContract -> CompiledProgram -> CheckedValue
  -> Maybe CheckedContract -> Maybe String
  -> Eff es (Either [Diagnostic] EvidenceSnapshotRef)
fetchEvidence context instanceRef package payload program config options = send . FetchEvidence context instanceRef package payload program config options
