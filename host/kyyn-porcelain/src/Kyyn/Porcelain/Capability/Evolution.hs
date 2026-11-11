module Kyyn.Porcelain.Capability.Evolution (applyEvolution, evaluateWorkspace, checkEvolution, checkSavedCandidate, acceptStoredEvolution) where

import Effectful (Eff, (:>))
import Kyyn.Domain.Evolution
import Kyyn.Domain.Git (LocalBranch, CommitMetadata)
import Kyyn.Domain.Diagnostic (CheckResult(..), ValidationReport(..), errorDiagnostic)
import Kyyn.Domain.Publication (AcceptanceResult(..), AcceptanceProblem(..))
import Kyyn.Domain.Root (Root(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), EvolutionState(..))
import Kyyn.Porcelain.Capability.EvolutionExecution (EvolutionExecution, evaluateEvolution)
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore, StoredCandidate, saveCandidate, saveCheckedCandidate, loadCandidate, readEvolutionState)
import Kyyn.Porcelain.Capability.EvolutionAuthoring (EvolutionAuthoring, captureEvolution)
import Kyyn.Porcelain.Capability.RootPublication (RootPublication, acceptEvolution)
import Kyyn.Porcelain.Capability.RootExecution (RootExecution)
import Kyyn.Porcelain.Capability.Validation (checkCandidate)
import Kyyn.Porcelain.Capability.RootStore (RootStore, materializeRoot)
import Kyyn.Porcelain.Validated (Validated)

evaluateWorkspace :: (EvolutionAuthoring :> es, EvolutionExecution :> es, EvolutionStore :> es, RootStore :> es)
  => EvolutionWorkspace -> Eff es (Either PreviewRejection (Candidate Root))
evaluateWorkspace workspace = do
  captured <- captureEvolution workspace
  either (pure . Left . ProposedCodeRejected) applyEvolution captured

checkEvolution :: (EvolutionAuthoring :> es, EvolutionExecution :> es, EvolutionStore :> es,
    RootExecution :> es, RootStore :> es)
  => EvolutionWorkspace -> Eff es (Either PreviewRejection (CheckResult (Candidate (Validated Root))))
checkEvolution workspace = do
  captured <- captureEvolution workspace
  evaluated <- either (pure . Left . ProposedCodeRejected) applyStoredEvolution captured
  traverse (\(stored,candidate) -> do
    checked <- checkCandidate candidate
    case checked of
      Passed validated _ -> saveCheckedCandidate stored validated
      _ -> pure ()
    pure checked) evaluated

checkSavedCandidate :: (EvolutionStore :> es, RootExecution :> es, RootStore :> es)
  => EvolutionWorkspace -> Eff es (CheckResult (Candidate (Validated Root)))
checkSavedCandidate workspace = do
  loaded <- loadCandidate workspace
  case loaded of
    Left diagnostics -> pure (Rejected (ValidationReport diagnostics))
    Right Nothing -> pure (Rejected (ValidationReport [errorDiagnostic "evolution.no-candidate"
      "Check this evolution first; no saved candidate is available"]))
    Right (Just candidate) -> checkCandidate candidate

applyEvolution :: (EvolutionExecution :> es, EvolutionStore :> es, RootStore :> es)
  => CapturedEvolution -> Eff es (Either PreviewRejection (Candidate Root))
applyEvolution captured = fmap (fmap snd) (applyStoredEvolution captured)

applyStoredEvolution :: (EvolutionExecution :> es, EvolutionStore :> es, RootStore :> es)
  => CapturedEvolution -> Eff es (Either PreviewRejection (StoredCandidate, Candidate Root))
applyStoredEvolution captured = do
  evaluated <- evaluateEvolution captured
  case evaluated of
    Left rejection -> pure (Left rejection)
    Right (EvaluatedEvolution capturedValue (After schema) value report) -> do
      let CapturedEvolution context _ _ = capturedValue
          EvolutionContext _ _ _ (WorkspaceSnapshot _ target _ _) = context
      materialized <- materializeRoot schema target value
      case materialized of
        Left diagnostics -> pure (Left (ProposedCodeRejected diagnostics))
        Right root -> do
          let candidate = Candidate context report root
          stored <- saveCandidate candidate
          pure (Right (stored,candidate))

acceptStoredEvolution :: (RootPublication :> es, EvolutionStore :> es, RootExecution :> es, RootStore :> es)
  => LocalBranch -> CommitMetadata -> EvolutionWorkspace -> Eff es AcceptanceResult
acceptStoredEvolution branch metadata workspace = do
  state <- readEvolutionState workspace
  case state of
    Left diagnostics -> pure (NotAccepted (InvalidMaterial diagnostics))
    Right observed | observed /= Ready -> pure (NotAccepted (NotReady observed))
    Right _ -> do
      checked <- checkSavedCandidate workspace
      case checked of
        Rejected (ValidationReport diagnostics) -> pure (NotAccepted (InvalidMaterial diagnostics))
        Passed value _ -> acceptEvolution branch metadata value
