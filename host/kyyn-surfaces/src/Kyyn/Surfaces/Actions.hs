module Kyyn.Surfaces.Actions
  ( inspectRoot, evaluateWorkspace, checkWorkspace ) where

import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Evolution
import Kyyn.Domain.Git (GitRevision, TreePath(..), revisionName)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Porcelain.Capability.Evolution (applyEvolution)
import Kyyn.Porcelain.Capability.EvolutionAuthoring (EvolutionAuthoring, captureEvolution)
import Kyyn.Porcelain.Capability.EvolutionExecution (EvolutionExecution)
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore, loadCandidate)
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadRootAt)
import Kyyn.Porcelain.Capability.RootExecution (RootExecution)
import Kyyn.Porcelain.Capability.RootStore (RootStore, rootLocation, loadRootValueForChecking)
import Kyyn.Porcelain.Capability.Validation (checkRoot, checkCandidate)
import Kyyn.Porcelain.Validated (validatedValue)
import Kyyn.Surfaces.Cli (RootCommand(..))
import Kyyn.Surfaces.Result

inspectRoot :: (RootOpening :> es, RootExecution :> es, RootStore :> es)
  => KnowledgeBase -> GitRevision -> RootCommand -> Eff es Response
inspectRoot kb@(KnowledgeBase repository _) revision request = case rootLocation kb of
  Left message -> pure (refusal [errorDiagnostic "kb.path" message])
  Right path -> do
    loaded <- loadRootAt repository revision (Subtree path)
    case loaded of
      Left diagnostics -> pure (refusal diagnostics)
      Right root -> do
        checked <- checkRoot root
        case checked of
          Rejected diagnostics -> pure (validationResult subject diagnostics False)
          Passed validated diagnostics@(ValidationReport warnings) -> case request of
            CheckRoot -> pure (validationResult subject diagnostics True)
            ShowRoot -> do
              value <- loadRootValueForChecking (validatedValue validated)
              pure $ case value of
                Left errors -> refusal errors
                Right facts -> case rootResult revision root facts of
                  Response outcome result text _ -> Response outcome result text warnings
  where subject = "Root at " ++ revisionName revision

evaluateWorkspace :: (EvolutionAuthoring :> es, EvolutionExecution :> es, EvolutionStore :> es, RootStore :> es)
  => EvolutionWorkspace -> Eff es Response
evaluateWorkspace workspace = do
  captured <- captureEvolution workspace
  case captured of
    Left diagnostics -> pure (refusal diagnostics)
    Right selected -> either previewRefusal candidateResult <$> applyEvolution selected

checkWorkspace :: (EvolutionStore :> es, RootExecution :> es, RootStore :> es)
  => EvolutionWorkspace -> Eff es Response
checkWorkspace workspace@(EvolutionWorkspace _ identity) = do
  loaded <- loadCandidate workspace
  case loaded of
    Left diagnostics -> pure (refusal diagnostics)
    Right Nothing -> pure (refusal [errorDiagnostic "evolution.no-candidate" "Evaluate this evolution before checking it; no saved candidate is available"])
    Right (Just candidate) -> do
      checked <- checkCandidate candidate
      pure $ case checked of
        Rejected report -> validationResult subject report False
        Passed _ report -> validationResult subject report True
  where subject = "Candidate " ++ evolutionIdName identity
