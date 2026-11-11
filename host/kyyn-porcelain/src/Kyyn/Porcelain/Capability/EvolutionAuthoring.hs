{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvolutionAuthoring
  ( EvolutionAuthoring(..), createEvolution, createEvolutionWithInputTypes, createFactProposal, captureEvolution ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FactProposal (FactProposal)
import Kyyn.Domain.Evolution (EvolutionName, EvolutionWorkspace, CapturedEvolution)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Workspace (EvolutionKind)
import Kyyn.Types.KnowledgeBase (RecipeId)

data EvolutionAuthoring :: Effect where
  CreateEvolution :: KnowledgeBase -> EvolutionName -> GitRevision -> EvolutionKind -> Bool
    -> EvolutionAuthoring m (Either [Diagnostic] EvolutionWorkspace)
  CreateFactProposal :: KnowledgeBase -> EvolutionName -> GitRevision -> RecipeId -> FactProposal
    -> EvolutionAuthoring m (Either [Diagnostic] EvolutionWorkspace)
  CaptureEvolution :: EvolutionWorkspace
    -> EvolutionAuthoring m (Either [Diagnostic] CapturedEvolution)

type instance DispatchOf EvolutionAuthoring = Dynamic

createEvolution :: EvolutionAuthoring :> es => KnowledgeBase -> EvolutionName -> GitRevision -> EvolutionKind
  -> Eff es (Either [Diagnostic] EvolutionWorkspace)
createEvolution kb name revision kind = createEvolutionWithInputTypes kb name revision kind False

createEvolutionWithInputTypes :: EvolutionAuthoring :> es => KnowledgeBase -> EvolutionName -> GitRevision -> EvolutionKind -> Bool
  -> Eff es (Either [Diagnostic] EvolutionWorkspace)
createEvolutionWithInputTypes kb name revision kind = send . CreateEvolution kb name revision kind

createFactProposal :: EvolutionAuthoring :> es => KnowledgeBase -> EvolutionName -> GitRevision
  -> RecipeId -> FactProposal -> Eff es (Either [Diagnostic] EvolutionWorkspace)
createFactProposal kb name revision recipe = send . CreateFactProposal kb name revision recipe

captureEvolution :: EvolutionAuthoring :> es => EvolutionWorkspace
  -> Eff es (Either [Diagnostic] CapturedEvolution)
captureEvolution = send . CaptureEvolution
