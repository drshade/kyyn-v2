{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvidenceStore
  ( EvidenceStore(..), evidenceHead
  , clearEvidence, discardFetchBlobs
  , openCurrentEvidence, readCapturedEvidence, publishFetch
  , FetchBaseline(..), beginFetch
  ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Domain.Blob (BlobRef)
import Kyyn.Domain.EvidenceIndex (EvidenceSelection, EvidenceIndex)

data EvidenceStore :: Effect where
  BeginFetch :: EvidenceSelection -> CheckedContract -> Maybe CheckedContract
    -> EvidenceStore m (Either EvidenceProblem FetchBaseline)
  OpenCurrentEvidence :: EvidenceSelection -> EvidenceStore m (Either EvidenceProblem (Maybe EvidenceIndex))
  ReadCapturedEvidence :: EvidenceIndex -> EvidenceId -> EvidenceStore m (Either EvidenceProblem (Maybe (Evidence CheckedValue)))
  PublishFetch :: EvidenceSelection -> CheckedContract -> Maybe FetchId -> Maybe String
    -> [EvidenceChange CheckedValue] -> Maybe (CheckedContract,CheckedValue)
    -> EvidenceStore m (Either EvidenceProblem EvidenceSnapshotRef)
  DiscardFetchBlobs :: ConnectorInstanceRef -> Maybe FetchId -> [BlobRef] -> EvidenceStore m ()
  EvidenceHead :: ConnectorInstanceRef -> EvidenceStore m (Either EvidenceProblem (Maybe FetchId))
  ClearEvidence :: ConnectorInstanceRef -> EvidenceStore m Bool

type instance DispatchOf EvidenceStore = Dynamic

data FetchBaseline = FetchBaseline String (Maybe FetchId) (Maybe EvidenceIndex) (Maybe CheckedValue)
  deriving (Eq, Show)

beginFetch :: EvidenceStore :> es => EvidenceSelection -> CheckedContract -> Maybe CheckedContract
  -> Eff es (Either EvidenceProblem FetchBaseline)
beginFetch selection payload = send . BeginFetch selection payload

discardFetchBlobs :: EvidenceStore :> es => ConnectorInstanceRef -> Maybe FetchId -> [BlobRef] -> Eff es ()
discardFetchBlobs instanceRef base = send . DiscardFetchBlobs instanceRef base

evidenceHead :: EvidenceStore :> es => ConnectorInstanceRef -> Eff es (Either EvidenceProblem (Maybe FetchId))
evidenceHead = send . EvidenceHead
clearEvidence :: EvidenceStore :> es => ConnectorInstanceRef -> Eff es Bool
clearEvidence = send . ClearEvidence

openCurrentEvidence :: EvidenceStore :> es => EvidenceSelection -> Eff es (Either EvidenceProblem (Maybe EvidenceIndex))
openCurrentEvidence = send . OpenCurrentEvidence

readCapturedEvidence :: EvidenceStore :> es => EvidenceIndex -> EvidenceId
  -> Eff es (Either EvidenceProblem (Maybe (Evidence CheckedValue)))
readCapturedEvidence index = send . ReadCapturedEvidence index

publishFetch :: EvidenceStore :> es => EvidenceSelection -> CheckedContract -> Maybe FetchId -> Maybe String
  -> [EvidenceChange CheckedValue] -> Maybe (CheckedContract,CheckedValue)
  -> Eff es (Either EvidenceProblem EvidenceSnapshotRef)
publishFetch selected contract base options changes = send . PublishFetch selected contract base options changes
