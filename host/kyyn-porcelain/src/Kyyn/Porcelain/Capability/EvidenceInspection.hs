{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvidenceInspection
  ( EvidenceInspection(..), selectEvidence, currentEvidence, readCurrentEvidence ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Domain.EvidenceIndex (EvidenceSelection)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Plugin (PluginName, ConnectorName)
import Kyyn.Domain.Value (CheckedValue)

data EvidenceInspection :: Effect where
  SelectEvidence :: KnowledgeBase -> GitRevision -> PluginName -> ConnectorName
    -> EvidenceInspection m (Either [Diagnostic] EvidenceSelection)
  ListCurrentEvidence :: EvidenceSelection
    -> EvidenceInspection m (Either [Diagnostic] EvidenceCapture)
  ReadCurrentEvidence :: EvidenceSelection -> EvidenceId
    -> EvidenceInspection m (Either [Diagnostic] (EvidenceSnapshotRef, FetchSummary, CheckedContract, Maybe (Evidence CheckedValue)))
type instance DispatchOf EvidenceInspection = Dynamic

selectEvidence :: EvidenceInspection :> es => KnowledgeBase -> GitRevision -> PluginName -> ConnectorName
  -> Eff es (Either [Diagnostic] EvidenceSelection)
selectEvidence kb revision plugin = send . SelectEvidence kb revision plugin

currentEvidence :: EvidenceInspection :> es
  => EvidenceSelection
  -> Eff es (Either [Diagnostic] EvidenceCapture)
currentEvidence = send . ListCurrentEvidence

readCurrentEvidence :: EvidenceInspection :> es
  => EvidenceSelection -> EvidenceId
  -> Eff es (Either [Diagnostic] (EvidenceSnapshotRef, FetchSummary, CheckedContract, Maybe (Evidence CheckedValue)))
readCurrentEvidence selection = send . ReadCurrentEvidence selection
