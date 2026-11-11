{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.Inspection
  ( Inspection(..), inspectSnapshot, inspectEvolutionSource ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evolution (EvolutionId, EvolutionWorkspace)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.Inspection
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)

data Inspection :: Effect where
  InspectSnapshot :: KnowledgeBase -> GitRevision -> Maybe EvolutionId
    -> Inspection m (Either [Diagnostic] SnapshotInspection)
  InspectEvolutionSource :: EvolutionWorkspace
    -> Inspection m (Either [Diagnostic] EvolutionInspection)

type instance DispatchOf Inspection = Dynamic

inspectSnapshot :: Inspection :> es => KnowledgeBase -> GitRevision -> Maybe EvolutionId
  -> Eff es (Either [Diagnostic] SnapshotInspection)
inspectSnapshot kb revision = send . InspectSnapshot kb revision

inspectEvolutionSource :: Inspection :> es => EvolutionWorkspace
  -> Eff es (Either [Diagnostic] EvolutionInspection)
inspectEvolutionSource = send . InspectEvolutionSource
