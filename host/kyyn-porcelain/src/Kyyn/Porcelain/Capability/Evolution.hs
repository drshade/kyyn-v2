module Kyyn.Porcelain.Capability.Evolution (applyEvolution) where

import Effectful (Eff, (:>))
import Kyyn.Domain.Evolution
import Kyyn.Domain.Root (Root)
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..))
import Kyyn.Porcelain.Capability.EvolutionExecution (EvolutionExecution, evaluateEvolution)
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore, saveCandidate)
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
