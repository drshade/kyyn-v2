{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvolutionStore
  ( EvolutionStore(..), createEvolution, captureEvolution, matchesCapturedInputs ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evolution (EvolutionName, EvolutionWorkspace, EvolutionContext, CapturedEvolution)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Git (GitRevision)

data EvolutionStore :: Effect where
  CreateEvolution :: KnowledgeBase -> EvolutionName -> GitRevision -> EvolutionStore m (Either [Diagnostic] EvolutionWorkspace)
  CaptureEvolution :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] CapturedEvolution)
  MatchesCapturedInputs :: EvolutionContext -> EvolutionStore m (Either [Diagnostic] Bool)

type instance DispatchOf EvolutionStore = Dynamic

createEvolution :: EvolutionStore :> es => KnowledgeBase -> EvolutionName -> GitRevision -> Eff es (Either [Diagnostic] EvolutionWorkspace)
createEvolution kb name = send . CreateEvolution kb name

captureEvolution :: EvolutionStore :> es => EvolutionWorkspace -> Eff es (Either [Diagnostic] CapturedEvolution)
captureEvolution = send . CaptureEvolution

matchesCapturedInputs :: EvolutionStore :> es => EvolutionContext -> Eff es (Either [Diagnostic] Bool)
matchesCapturedInputs = send . MatchesCapturedInputs
