{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvolutionAuthoring
  ( EvolutionAuthoring(..), createEvolution, createFactProposal, captureEvolution ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FactProposal (FactProposal)
import Kyyn.Domain.Evolution (EvolutionName, EvolutionWorkspace, CapturedEvolution)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Workspace (EvolutionKind)

data EvolutionAuthoring :: Effect where
  CreateEvolution :: KnowledgeBase -> EvolutionName -> GitRevision -> EvolutionKind
    -> EvolutionAuthoring m (Either [Diagnostic] EvolutionWorkspace)
  CreateFactProposal :: KnowledgeBase -> EvolutionName -> GitRevision -> FactProposal
    -> EvolutionAuthoring m (Either [Diagnostic] EvolutionWorkspace)
  CaptureEvolution :: EvolutionWorkspace
    -> EvolutionAuthoring m (Either [Diagnostic] CapturedEvolution)

type instance DispatchOf EvolutionAuthoring = Dynamic

createEvolution :: EvolutionAuthoring :> es => KnowledgeBase -> EvolutionName -> GitRevision -> EvolutionKind
  -> Eff es (Either [Diagnostic] EvolutionWorkspace)
createEvolution kb name revision = send . CreateEvolution kb name revision

createFactProposal :: EvolutionAuthoring :> es => KnowledgeBase -> EvolutionName -> GitRevision
  -> FactProposal -> Eff es (Either [Diagnostic] EvolutionWorkspace)
createFactProposal kb name revision = send . CreateFactProposal kb name revision

captureEvolution :: EvolutionAuthoring :> es => EvolutionWorkspace
  -> Eff es (Either [Diagnostic] CapturedEvolution)
captureEvolution = send . CaptureEvolution
