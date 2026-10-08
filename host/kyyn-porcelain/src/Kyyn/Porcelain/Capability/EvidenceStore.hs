{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvidenceStore
  ( EvidenceStore(..), evidenceHead, publishFetch, loadCurrentEvidence
  , clearEvidence, discardFetchBlobs
  , FetchBaseline(..), beginFetch, publishFetchWithPosition
  , openCurrentEvidence, readCapturedEvidence, publishIndexedFetch
  ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Domain.Blob (BlobRef)
import Kyyn.Domain.EvidenceIndex (EvidenceSelection, EvidenceIndex)

data EvidenceStore :: Effect where
  OpenCurrentEvidence :: EvidenceSelection -> EvidenceStore m (Either EvidenceProblem (Maybe EvidenceIndex))
  ReadCapturedEvidence :: EvidenceIndex -> EvidenceId -> EvidenceStore m (Either EvidenceProblem (Maybe (Evidence CheckedValue)))
  PublishIndexedFetch :: EvidenceSelection -> CheckedContract -> Maybe FetchId -> Maybe String
    -> [EvidenceChange CheckedValue] -> Maybe (CheckedContract,CheckedValue)
    -> EvidenceStore m (Either EvidenceProblem EvidenceSnapshotRef)
  DiscardFetchBlobs :: ConnectorInstanceRef -> Maybe FetchId -> [BlobRef] -> EvidenceStore m ()
  BeginFetch :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe CheckedContract
    -> EvidenceStore m (Either EvidenceProblem FetchBaseline)
  EvidenceHead :: ConnectorInstanceRef -> EvidenceStore m (Either EvidenceProblem (Maybe FetchId))
  PublishFetch :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe FetchId
    -> Maybe String
    -> [EvidenceChange CheckedValue] -> Maybe (CheckedContract,CheckedValue)
    -> EvidenceStore m (Either EvidenceProblem EvidenceSnapshotRef)
  LoadCurrentEvidence :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
    -> EvidenceStore m (Either EvidenceProblem (Maybe CurrentEvidence))
  ClearEvidence :: ConnectorInstanceRef -> EvidenceStore m Bool

type instance DispatchOf EvidenceStore = Dynamic

discardFetchBlobs :: EvidenceStore :> es => ConnectorInstanceRef -> Maybe FetchId -> [BlobRef] -> Eff es ()
discardFetchBlobs instanceRef base = send . DiscardFetchBlobs instanceRef base

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
clearEvidence :: EvidenceStore :> es => ConnectorInstanceRef -> Eff es Bool
clearEvidence = send . ClearEvidence

openCurrentEvidence :: EvidenceStore :> es => EvidenceSelection -> Eff es (Either EvidenceProblem (Maybe EvidenceIndex))
openCurrentEvidence = send . OpenCurrentEvidence

readCapturedEvidence :: EvidenceStore :> es => EvidenceIndex -> EvidenceId
  -> Eff es (Either EvidenceProblem (Maybe (Evidence CheckedValue)))
readCapturedEvidence index = send . ReadCapturedEvidence index

publishIndexedFetch :: EvidenceStore :> es => EvidenceSelection -> CheckedContract -> Maybe FetchId -> Maybe String
  -> [EvidenceChange CheckedValue] -> Maybe (CheckedContract,CheckedValue)
  -> Eff es (Either EvidenceProblem EvidenceSnapshotRef)
publishIndexedFetch selected contract base options changes = send . PublishIndexedFetch selected contract base options changes
