{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvolutionStore
  ( EvolutionStore(..), readWorkspace, matchesCapturedInputs, saveCandidate, loadCandidate, findAcceptance
  , listEvolutions, resolveEvolution, readEvolutionState, markReady, markDraft, exportAcceptedWorkspace, workspaceLocation
  , readEvolutionSummary, readArchivedReport, inspectEvolution ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evolution (EvolutionId, evolutionIdName, EvolutionWorkspace(..), EvolutionContext, Candidate(..), EvolutionFilter, EvolutionSummary(..))
import Kyyn.Domain.EvolutionReport (EvolutionReport)
import Kyyn.Domain.Workspace (EvolutionState, WorkspaceSnapshot)
import Kyyn.Domain.Root (Root)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase, knowledgeBasePath)
import Kyyn.Domain.Path (RelativePath, relativePath)
import Kyyn.Domain.Git (GitRevision, TreePath)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Porcelain.Validated (Validated)

workspaceLocation :: EvolutionWorkspace -> Either String RelativePath
workspaceLocation (EvolutionWorkspace kb identity) =
  relativePath ("evolutions/" ++ evolutionIdName identity) >>= knowledgeBasePath kb

data EvolutionStore :: Effect where
  ReadEvolutionSummary :: EvolutionWorkspace -> GitRevision -> EvolutionStore m (Either [Diagnostic] EvolutionSummary)
  ReadArchivedReport :: EvolutionWorkspace -> GitRevision -> EvolutionStore m (Either [Diagnostic] (Maybe EvolutionReport))
  ListEvolutions :: KnowledgeBase -> EvolutionFilter -> EvolutionStore m (Either [Diagnostic] [EvolutionSummary])
  ResolveEvolution :: KnowledgeBase -> EvolutionId -> EvolutionStore m (Either [Diagnostic] EvolutionWorkspace)
  ReadEvolutionState :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] EvolutionState)
  MarkReady :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] ())
  MarkDraft :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] ())
  ExportAcceptedWorkspace :: Candidate (Validated Root) -> EvolutionStore m (Either [Diagnostic] (TreePath, FileTree))
  ReadWorkspace :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] WorkspaceSnapshot)
  MatchesCapturedInputs :: EvolutionContext -> EvolutionStore m (Either [Diagnostic] Bool)
  SaveCandidate :: Candidate Root -> EvolutionStore m ()
  LoadCandidate :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] (Maybe (Candidate Root)))
  FindAcceptance :: KnowledgeBase -> EvolutionId -> GitRevision -> EvolutionStore m (Either [Diagnostic] (Maybe GitRevision))

type instance DispatchOf EvolutionStore = Dynamic

readEvolutionSummary :: EvolutionStore :> es => EvolutionWorkspace -> GitRevision -> Eff es (Either [Diagnostic] EvolutionSummary)
readEvolutionSummary workspace = send . ReadEvolutionSummary workspace

readArchivedReport :: EvolutionStore :> es => EvolutionWorkspace -> GitRevision -> Eff es (Either [Diagnostic] (Maybe EvolutionReport))
readArchivedReport workspace = send . ReadArchivedReport workspace

inspectEvolution :: EvolutionStore :> es => EvolutionWorkspace -> GitRevision
  -> Eff es (Either [Diagnostic] (EvolutionSummary, Maybe EvolutionReport))
inspectEvolution workspace revision = do
  summary <- readEvolutionSummary workspace revision
  case summary of
    Left diagnostics -> pure (Left diagnostics)
    Right value@(EvolutionSummary _ _ _ acceptance) -> do
      report <- case acceptance of
        Just _ -> readArchivedReport workspace revision
        Nothing -> fmap (fmap (fmap (\(Candidate _ report _) -> report))) (loadCandidate workspace)
      pure ((value,) <$> report)

readWorkspace :: EvolutionStore :> es => EvolutionWorkspace -> Eff es (Either [Diagnostic] WorkspaceSnapshot)
readWorkspace = send . ReadWorkspace

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

exportAcceptedWorkspace :: EvolutionStore :> es => Candidate (Validated Root) -> Eff es (Either [Diagnostic] (TreePath, FileTree))
exportAcceptedWorkspace = send . ExportAcceptedWorkspace
