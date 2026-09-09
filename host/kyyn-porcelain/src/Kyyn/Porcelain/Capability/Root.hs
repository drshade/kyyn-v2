module Kyyn.Porcelain.Capability.Root (checkRootAt, inspectRootAt) where

import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Git (GitRevision, TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Root (Root, CheckedValue)
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadRootAt)
import Kyyn.Porcelain.Capability.RootExecution (RootExecution)
import Kyyn.Porcelain.Capability.RootStore (RootStore, rootLocation, loadRootValueForChecking)
import Kyyn.Porcelain.Capability.Validation (checkRoot)
import Kyyn.Porcelain.Validated (Validated, validatedValue)

checkRootAt :: (RootOpening :> es, RootExecution :> es, RootStore :> es)
  => KnowledgeBase -> GitRevision -> Eff es (CheckResult (Validated Root))
checkRootAt kb@(KnowledgeBase repository _) revision = case rootLocation kb of
  Left message -> pure (Rejected (ValidationReport [errorDiagnostic "kb.path" message]))
  Right path -> do
    loaded <- loadRootAt repository revision (Subtree path)
    either (pure . Rejected . ValidationReport) checkRoot loaded

inspectRootAt :: (RootOpening :> es, RootExecution :> es, RootStore :> es)
  => KnowledgeBase -> GitRevision -> Eff es (CheckResult (Validated Root, CheckedValue))
inspectRootAt kb revision = do
  checked <- checkRootAt kb revision
  case checked of
    Rejected report -> pure (Rejected report)
    Passed root (ValidationReport warnings) -> do
      value <- loadRootValueForChecking (validatedValue root)
      pure $ case value of
        Left diagnostics -> Rejected (ValidationReport (warnings ++ diagnostics))
        Right facts -> Passed (root,facts) (ValidationReport warnings)
