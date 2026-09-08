{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvolutionAuthoring
  ( EvolutionAuthoring(..), createEvolution, captureEvolution ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evolution (EvolutionName, EvolutionWorkspace, CapturedEvolution)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)

data EvolutionAuthoring :: Effect where
  CreateEvolution :: KnowledgeBase -> EvolutionName -> GitRevision
    -> EvolutionAuthoring m (Either [Diagnostic] EvolutionWorkspace)
  CaptureEvolution :: EvolutionWorkspace
    -> EvolutionAuthoring m (Either [Diagnostic] CapturedEvolution)

type instance DispatchOf EvolutionAuthoring = Dynamic

createEvolution :: EvolutionAuthoring :> es => KnowledgeBase -> EvolutionName -> GitRevision
  -> Eff es (Either [Diagnostic] EvolutionWorkspace)
createEvolution kb name = send . CreateEvolution kb name

captureEvolution :: EvolutionAuthoring :> es => EvolutionWorkspace
  -> Eff es (Either [Diagnostic] CapturedEvolution)
captureEvolution = send . CaptureEvolution
