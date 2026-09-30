module Kyyn.Porcelain.Capability.Evolution (applyEvolution, evaluateWorkspace, checkEvolution, checkSavedCandidate, acceptStoredEvolution) where

import Effectful (Eff, (:>))
import Kyyn.Domain.Evolution
import Kyyn.Domain.Git (LocalBranch, CommitMetadata)
import Kyyn.Domain.Diagnostic (CheckResult(..), ValidationReport(..), errorDiagnostic)
import Kyyn.Domain.Publication (AcceptanceResult(..), AcceptanceProblem(..))
import Kyyn.Domain.Root (Root(..))
import qualified Kyyn.Types.KnowledgeBase as Value
import Kyyn.Domain.EvolutionReport (EvolutionReport(..))
import Kyyn.Porcelain.Capability.Curation (resolveCuration)
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore)
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..))
import Kyyn.Porcelain.Capability.EvolutionExecution (EvolutionExecution, evaluateEvolution)
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore, saveCandidate, loadCandidate)
import Kyyn.Porcelain.Capability.EvolutionAuthoring (EvolutionAuthoring, captureEvolution)
import Kyyn.Porcelain.Capability.RootPublication (RootPublication, findAcceptanceOnBranch, acceptEvolution, alreadyAccepted)
import Kyyn.Porcelain.Capability.RootExecution (RootExecution)
import Kyyn.Porcelain.Capability.Validation (checkCandidate)
import Kyyn.Porcelain.Capability.RootStore (RootStore, materializeRoot)
import Kyyn.Porcelain.Validated (Validated)

evaluateWorkspace :: (EvolutionAuthoring :> es, EvolutionExecution :> es, EvolutionStore :> es, RootStore :> es, EvidenceStore :> es)
  => EvolutionWorkspace -> Eff es (Either PreviewRejection (Candidate Root))
evaluateWorkspace workspace = do
  captured <- captureEvolution workspace
  either (pure . Left . ProposedCodeRejected) applyEvolution captured

checkEvolution :: (EvolutionAuthoring :> es, EvolutionExecution :> es, EvolutionStore :> es,
    RootExecution :> es, RootStore :> es, EvidenceStore :> es)
  => EvolutionWorkspace -> Eff es (Either PreviewRejection (CheckResult (Candidate (Validated Root))))
checkEvolution workspace = do
  evaluated <- evaluateWorkspace workspace
  traverse checkCandidate evaluated

checkSavedCandidate :: (EvolutionStore :> es, RootExecution :> es, RootStore :> es)
  => EvolutionWorkspace -> Eff es (CheckResult (Candidate (Validated Root)))
checkSavedCandidate workspace = do
  loaded <- loadCandidate workspace
  case loaded of
    Left diagnostics -> pure (Rejected (ValidationReport diagnostics))
    Right Nothing -> pure (Rejected (ValidationReport [errorDiagnostic "evolution.no-candidate"
      "Check this evolution first; no saved candidate is available"]))
    Right (Just candidate) -> checkCandidate candidate

applyEvolution :: (EvolutionExecution :> es, EvolutionStore :> es, RootStore :> es, EvidenceStore :> es)
  => CapturedEvolution -> Eff es (Either PreviewRejection (Candidate Root))
applyEvolution captured = do
  evaluated <- evaluateEvolution captured
  case evaluated of
    Left rejection -> pure (Left rejection)
    Right (EvaluatedEvolution (CapturedEvolution context@(EvolutionContext _ _ _
        (WorkspaceSnapshot _ _ target _ _)) (Root _ _ _ progress _) _ _)
        (After schema) value@(Value.KnowledgeBase _ recipes) report@(EvolutionReport _ _ curation)) -> do
      materialized <- materializeRoot schema target value
      case materialized of
        Left diagnostics -> pure (Left (ProposedCodeRejected diagnostics))
        Right root -> do
          resolved <- resolveCuration recipes curation progress
          case resolved of
            Left diagnostics -> pure (Left (ProposedCodeRejected diagnostics))
            Right next -> do
              let candidate = Candidate context report root { curation = next }
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
      checked <- checkSavedCandidate workspace
      case checked of
        Rejected (ValidationReport diagnostics) -> pure (NotAccepted (InvalidMaterial diagnostics))
        Passed value _ -> acceptEvolution branch metadata value
