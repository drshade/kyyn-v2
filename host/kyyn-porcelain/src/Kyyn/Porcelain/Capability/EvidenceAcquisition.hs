{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvidenceAcquisition (EvidenceAcquisition(..), fetchEvidence) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evidence (EvidenceSnapshotRef, SyncMode)
import Kyyn.Domain.EvidenceIndex (EvidenceSelection)
import Kyyn.Domain.Value (CheckedValue)

data EvidenceAcquisition :: Effect where
  FetchEvidence :: EvidenceSelection -> CheckedContract -> CompiledProgram -> CheckedValue
    -> Maybe CheckedContract -> Maybe CheckedContract -> SyncMode -> Maybe String
    -> EvidenceAcquisition m (Either [Diagnostic] EvidenceSnapshotRef)

type instance DispatchOf EvidenceAcquisition = Dynamic

fetchEvidence :: EvidenceAcquisition :> es
  => EvidenceSelection -> CheckedContract -> CompiledProgram -> CheckedValue
  -> Maybe CheckedContract -> Maybe CheckedContract -> SyncMode -> Maybe String
  -> Eff es (Either [Diagnostic] EvidenceSnapshotRef)
fetchEvidence selection payload program config options position mode = send . FetchEvidence selection payload program config options position mode
