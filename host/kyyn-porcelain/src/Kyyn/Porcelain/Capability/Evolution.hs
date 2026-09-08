module Kyyn.Porcelain.Capability.Evolution (applyEvolution, acceptStoredEvolution) where

import Effectful (Eff, (:>))
import Kyyn.Domain.Evolution
import Kyyn.Domain.Git (LocalBranch, CommitMetadata)
import Kyyn.Domain.Diagnostic (CheckResult(..), ValidationReport(..), errorDiagnostic)
import Kyyn.Domain.Publication (AcceptanceResult(..), AcceptanceProblem(..))
import Kyyn.Domain.Root (Root)
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..))
import Kyyn.Porcelain.Capability.EvolutionExecution (EvolutionExecution, evaluateEvolution)
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore, saveCandidate, loadCandidate)
import Kyyn.Porcelain.Capability.RootPublication (RootPublication, findAcceptanceOnBranch, acceptEvolution, alreadyAccepted)
import Kyyn.Porcelain.Capability.RootExecution (RootExecution)
import Kyyn.Porcelain.Capability.Validation (checkCandidate)
import Kyyn.Porcelain.Capability.RootStore (RootStore, materializeRoot)

applyEvolution :: (EvolutionExecution :> es, EvolutionStore :> es, RootStore :> es)
  => CapturedEvolution -> Eff es (Either PreviewRejection (Candidate Root))
applyEvolution captured = do
  evaluated <- evaluateEvolution captured
  case evaluated of
    Left rejection -> pure (Left rejection)
    Right (EvaluatedEvolution (CapturedEvolution context@(EvolutionContext _ _ _
        (WorkspaceSnapshot _ _ target _ _))) (After schema) value report) -> do
      materialized <- materializeRoot schema target value
      case materialized of
        Left diagnostics -> pure (Left (ProposedCodeRejected diagnostics))
        Right root -> do
          let candidate = Candidate context report root
          saveCandidate candidate
          pure (Right candidate)

acceptStoredEvolution :: (RootPublication :> es, EvolutionStore :> es, RootExecution :> es, RootStore :> es)
  => LocalBranch -> CommitMetadata -> EvolutionWorkspace -> Eff es AcceptanceResult
acceptStoredEvolution branch metadata workspace = do
  accepted <- findAcceptanceOnBranch branch workspace
  case accepted of
    Left diagnostics -> pure (NotAccepted (InvalidMaterial diagnostics))
    Right (Just revision) -> pure (alreadyAccepted revision)
    Right Nothing -> do
      loaded <- loadCandidate workspace
      case loaded of
        Left diagnostics -> pure (NotAccepted (InvalidMaterial diagnostics))
        Right Nothing -> pure (NotAccepted (InvalidMaterial [errorDiagnostic "evolution.no-candidate"
          "Evaluate this evolution before accepting it; no saved candidate is available"]))
        Right (Just candidate) -> do
          checked <- checkCandidate candidate
          case checked of
            Rejected (ValidationReport diagnostics) -> pure (NotAccepted (InvalidMaterial diagnostics))
            Passed value _ -> acceptEvolution branch metadata value
