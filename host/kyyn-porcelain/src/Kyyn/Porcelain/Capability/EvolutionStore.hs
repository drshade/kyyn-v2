{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvolutionStore
  ( EvolutionStore(..), createEvolution, captureEvolution, matchesCapturedInputs, saveCandidate, loadCandidate, findAcceptance
  , listEvolutions, resolveEvolution, readEvolutionState, markReady, markDraft ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evolution (EvolutionId, EvolutionName, EvolutionWorkspace, EvolutionContext, CapturedEvolution, Candidate, EvolutionFilter, EvolutionSummary)
import Kyyn.Domain.Workspace (EvolutionState)
import Kyyn.Domain.Root (Root)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Git (GitRevision)

data EvolutionStore :: Effect where
  ListEvolutions :: KnowledgeBase -> EvolutionFilter -> EvolutionStore m (Either [Diagnostic] [EvolutionSummary])
  ResolveEvolution :: KnowledgeBase -> EvolutionId -> EvolutionStore m (Either [Diagnostic] EvolutionWorkspace)
  ReadEvolutionState :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] EvolutionState)
  MarkReady :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] ())
  MarkDraft :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] ())
  CreateEvolution :: KnowledgeBase -> EvolutionName -> GitRevision -> EvolutionStore m (Either [Diagnostic] EvolutionWorkspace)
  CaptureEvolution :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] CapturedEvolution)
  MatchesCapturedInputs :: EvolutionContext -> EvolutionStore m (Either [Diagnostic] Bool)
  SaveCandidate :: Candidate Root -> EvolutionStore m ()
  LoadCandidate :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] (Maybe (Candidate Root)))
  FindAcceptance :: KnowledgeBase -> EvolutionId -> GitRevision -> EvolutionStore m (Either [Diagnostic] (Maybe GitRevision))

type instance DispatchOf EvolutionStore = Dynamic

createEvolution :: EvolutionStore :> es => KnowledgeBase -> EvolutionName -> GitRevision -> Eff es (Either [Diagnostic] EvolutionWorkspace)
createEvolution kb name = send . CreateEvolution kb name

captureEvolution :: EvolutionStore :> es => EvolutionWorkspace -> Eff es (Either [Diagnostic] CapturedEvolution)
captureEvolution = send . CaptureEvolution

matchesCapturedInputs :: EvolutionStore :> es => EvolutionContext -> Eff es (Either [Diagnostic] Bool)
matchesCapturedInputs = send . MatchesCapturedInputs

saveCandidate :: EvolutionStore :> es => Candidate Root -> Eff es ()
saveCandidate = send . SaveCandidate

loadCandidate :: EvolutionStore :> es => EvolutionWorkspace -> Eff es (Either [Diagnostic] (Maybe (Candidate Root)))
loadCandidate = send . LoadCandidate

findAcceptance :: EvolutionStore :> es => KnowledgeBase -> EvolutionId -> GitRevision -> Eff es (Either [Diagnostic] (Maybe GitRevision))
findAcceptance kb identity = send . FindAcceptance kb identity

listEvolutions :: EvolutionStore :> es => KnowledgeBase -> EvolutionFilter -> Eff es (Either [Diagnostic] [EvolutionSummary])
listEvolutions kb = send . ListEvolutions kb

resolveEvolution :: EvolutionStore :> es => KnowledgeBase -> EvolutionId -> Eff es (Either [Diagnostic] EvolutionWorkspace)
resolveEvolution kb = send . ResolveEvolution kb

readEvolutionState :: EvolutionStore :> es => EvolutionWorkspace -> Eff es (Either [Diagnostic] EvolutionState)
readEvolutionState = send . ReadEvolutionState

markReady :: EvolutionStore :> es => EvolutionWorkspace -> Eff es (Either [Diagnostic] ())
markReady = send . MarkReady

markDraft :: EvolutionStore :> es => EvolutionWorkspace -> Eff es (Either [Diagnostic] ())
markDraft = send . MarkDraft
