{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvidenceStore
  ( EvidenceStore(..), evidenceHead, publishFetch, selectEvidence, loadEvidenceSnapshot, readEvidence, listEvidenceIds
  , readFetchesBetween, listEvidenceChanges, deleteEvidenceHistory, clearEvidence
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
  SelectEvidence :: ConnectorInstanceRef -> EvidenceProducer -> EvidenceSelection
    -> EvidenceStore m (Either EvidenceProblem EvidenceSnapshotRef)
  LoadEvidenceSnapshot :: EvidenceSnapshotRef -> CheckedContract
    -> EvidenceStore m (Either EvidenceProblem [(EvidenceId, Evidence CheckedValue)])
  ReadEvidence :: EvidenceSnapshotRef -> CheckedContract -> EvidenceId
    -> EvidenceStore m (Either EvidenceProblem (Maybe (Evidence CheckedValue)))
  ListEvidenceIds :: EvidenceSnapshotRef -> CheckedContract
    -> EvidenceStore m (Either EvidenceProblem [EvidenceId])
  ReadFetchesBetween :: EvidenceSnapshotRef -> CheckedContract -> Maybe FetchId
    -> EvidenceStore m (Either EvidenceProblem [Fetch CheckedValue])
  ListEvidenceChanges :: EvidenceSnapshotRef -> CheckedContract -> Maybe FetchId
    -> EvidenceStore m (Either EvidenceProblem [EvidenceChangeSummary])
  DeleteEvidenceHistory :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
    -> EvidenceStore m (Either EvidenceProblem ())
  ClearEvidence :: ConnectorInstanceRef -> EvidenceStore m ()

type instance DispatchOf EvidenceStore = Dynamic

evidenceHead :: EvidenceStore :> es => ConnectorInstanceRef -> Eff es (Either EvidenceProblem (Maybe FetchId))
evidenceHead = send . EvidenceHead
publishFetch :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Maybe FetchId -> [EvidenceChange CheckedValue] -> Eff es (Either EvidenceProblem EvidenceSnapshotRef)
publishFetch instanceRef producer contract base = send . PublishFetch instanceRef producer contract base
selectEvidence :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> EvidenceSelection
  -> Eff es (Either EvidenceProblem EvidenceSnapshotRef)
selectEvidence instanceRef producer = send . SelectEvidence instanceRef producer
loadEvidenceSnapshot :: EvidenceStore :> es => EvidenceSnapshotRef -> CheckedContract
  -> Eff es (Either EvidenceProblem [(EvidenceId, Evidence CheckedValue)])
loadEvidenceSnapshot snapshot = send . LoadEvidenceSnapshot snapshot
readEvidence :: EvidenceStore :> es => EvidenceSnapshotRef -> CheckedContract -> EvidenceId
  -> Eff es (Either EvidenceProblem (Maybe (Evidence CheckedValue)))
readEvidence snapshot contract = send . ReadEvidence snapshot contract
listEvidenceIds :: EvidenceStore :> es => EvidenceSnapshotRef -> CheckedContract
  -> Eff es (Either EvidenceProblem [EvidenceId])
listEvidenceIds snapshot = send . ListEvidenceIds snapshot
readFetchesBetween :: EvidenceStore :> es => EvidenceSnapshotRef -> CheckedContract -> Maybe FetchId
  -> Eff es (Either EvidenceProblem [Fetch CheckedValue])
readFetchesBetween snapshot contract = send . ReadFetchesBetween snapshot contract
listEvidenceChanges :: EvidenceStore :> es => EvidenceSnapshotRef -> CheckedContract -> Maybe FetchId
  -> Eff es (Either EvidenceProblem [EvidenceChangeSummary])
listEvidenceChanges snapshot contract = send . ListEvidenceChanges snapshot contract
deleteEvidenceHistory :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Eff es (Either EvidenceProblem ())
deleteEvidenceHistory instanceRef producer = send . DeleteEvidenceHistory instanceRef producer
clearEvidence :: EvidenceStore :> es => ConnectorInstanceRef -> Eff es ()
clearEvidence = send . ClearEvidence
