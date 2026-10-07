{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvidenceStore
  ( EvidenceStore(..), evidenceHead, publishFetch, loadCurrentEvidence
  , readFetchHistory, listEvidenceChanges, clearEvidence, resolveEvidenceCapture
  , FetchBaseline(..), beginFetch, publishFetchWithPosition
  ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Value (CheckedValue)

data EvidenceStore :: Effect where
  BeginFetch :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe CheckedContract
    -> EvidenceStore m (Either EvidenceProblem FetchBaseline)
  EvidenceHead :: ConnectorInstanceRef -> EvidenceStore m (Either EvidenceProblem (Maybe FetchId))
  PublishFetch :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe FetchId
    -> Maybe String
    -> [EvidenceChange CheckedValue] -> Maybe (CheckedContract,CheckedValue)
    -> EvidenceStore m (Either EvidenceProblem EvidenceSnapshotRef)
  LoadCurrentEvidence :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
    -> EvidenceStore m (Either EvidenceProblem (Maybe CurrentEvidence))
  ReadFetchHistory :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
    -> EvidenceStore m (Either EvidenceProblem (EvidenceSnapshotRef, [FetchSummary]))
  ListEvidenceChanges :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe FetchId
    -> EvidenceStore m (Either EvidenceProblem (EvidenceSnapshotRef, [EvidenceChangeSummary]))
  ClearEvidence :: ConnectorInstanceRef -> EvidenceStore m Bool
  ResolveEvidenceCapture :: ConnectorInstanceRef -> FetchId
    -> EvidenceStore m (Either EvidenceProblem EvidenceCapture)

type instance DispatchOf EvidenceStore = Dynamic

data FetchBaseline = FetchBaseline
  { startedAt :: String, expectedHead :: Maybe FetchId
  , priorCapture :: Maybe CurrentEvidence, priorPosition :: Maybe CheckedValue
  } deriving (Eq, Show)

beginFetch :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe CheckedContract
  -> Eff es (Either EvidenceProblem FetchBaseline)
beginFetch instanceRef producer payload = send . BeginFetch instanceRef producer payload

evidenceHead :: EvidenceStore :> es => ConnectorInstanceRef -> Eff es (Either EvidenceProblem (Maybe FetchId))
evidenceHead = send . EvidenceHead
publishFetch :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Maybe FetchId -> Maybe String -> [EvidenceChange CheckedValue] -> Eff es (Either EvidenceProblem EvidenceSnapshotRef)
publishFetch instanceRef producer contract base options changes = publishFetchWithPosition instanceRef producer contract base options changes Nothing

publishFetchWithPosition :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Maybe FetchId -> Maybe String -> [EvidenceChange CheckedValue] -> Maybe (CheckedContract,CheckedValue)
  -> Eff es (Either EvidenceProblem EvidenceSnapshotRef)
publishFetchWithPosition instanceRef producer contract base options changes = send . PublishFetch instanceRef producer contract base options changes
loadCurrentEvidence :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Eff es (Either EvidenceProblem (Maybe CurrentEvidence))
loadCurrentEvidence instanceRef producer = send . LoadCurrentEvidence instanceRef producer
readFetchHistory :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Eff es (Either EvidenceProblem (EvidenceSnapshotRef, [FetchSummary]))
readFetchHistory instanceRef producer = send . ReadFetchHistory instanceRef producer
listEvidenceChanges :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe FetchId
  -> Eff es (Either EvidenceProblem (EvidenceSnapshotRef, [EvidenceChangeSummary]))
listEvidenceChanges instanceRef producer contract = send . ListEvidenceChanges instanceRef producer contract
clearEvidence :: EvidenceStore :> es => ConnectorInstanceRef -> Eff es Bool
clearEvidence = send . ClearEvidence

resolveEvidenceCapture :: EvidenceStore :> es => ConnectorInstanceRef -> FetchId
  -> Eff es (Either EvidenceProblem EvidenceCapture)
resolveEvidenceCapture instanceRef = send . ResolveEvidenceCapture instanceRef
