{-# LANGUAGE GADTs, LambdaCase, OverloadedStrings #-}
module Kyyn.Porcelain.Interpreter.Inspection (runInspection) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (nub, sort)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Git (TreePath(..))
import Kyyn.Domain.Inspection
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Root (Root(..), isRootMaterial)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionState(..))
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Porcelain.Capability.Inspection
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Store
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadRootAt)
import Kyyn.Porcelain.Capability.RootStore (RootStore, rootLocation, loadRootValueForChecking)

runInspection :: (RootOpening :> es, RootStore :> es, Store.EvolutionStore :> es, Git.Git :> es)
  => Eff (Inspection : es) a -> Eff es a
runInspection = interpret $ \_ -> \case
  InspectSnapshot kb@(KnowledgeBase repository _) revision selected -> runExceptT $ do
    (base,root@(Root contract _ _ _)) <- case selected of
      Nothing -> do
        path <- checked (rootLocation kb)
        (revision,) <$> ExceptT (loadRootAt repository revision (Subtree path))
      Just identity -> do
        let workspace = EvolutionWorkspace kb identity
        state <- ExceptT (Store.readEvolutionState workspace)
        case state of
          Accepted -> throwE [errorDiagnostic "inspection.accepted" "This evolution is accepted; use the accepted KB link"]
          _ -> pure ()
        candidate <- ExceptT (Store.loadCheckedCandidate workspace)
        case candidate of
          Nothing -> throwE [errorDiagnostic "evolution.no-candidate" "No successfully checked candidate is available"]
          Just (Candidate (EvolutionContext _ _ before _) _ root) -> pure (beforeRevision before,root)
    CheckedValue _ value <- ExceptT (loadRootValueForChecking root)
    pure (SnapshotInspection base selected contract value)
  InspectEvolutionSource workspace@(EvolutionWorkspace kb@(KnowledgeBase repository _) _) -> runExceptT $ do
    live@(WorkspaceSnapshot manifest@(WorkspaceManifest _ _ _ state _) _ _ _) <- ExceptT (Store.readWorkspace workspace)
    (WorkspaceSnapshot captured@(WorkspaceManifest base name explanation _ kind) target _ _,saved,report) <-
      case state of
        Accepted -> (live,True,) <$> ExceptT (Store.readArchivedReport workspace)
        _ -> do
          candidate <- ExceptT (Store.loadCheckedCandidate workspace)
          pure $ case candidate of
            Just (Candidate (EvolutionContext _ _ _ snapshot) steps _) -> (snapshot,True,Just steps)
            Nothing -> (live,False,Nothing)
    path <- checked (rootLocation kb)
    previous <- ExceptT (Git.readTreeAt repository base (Subtree path))
    let before = filter (not . isRootMaterial . fst) (files previous)
        after = files target
        changes = [SourceChange key old new | key <- sort (nub (map fst before ++ map fst after)),
          let old = lookup key before, let new = lookup key after, old /= new]
        selectedManifest = if saved then WorkspaceManifest base name explanation state kind else manifest
    -- Lifecycle state is current; explanation/base/source belong to the labelled capture.
    captured `seq` pure (EvolutionInspection selectedManifest saved report changes)
  where checked = either (throwE . pure . errorDiagnostic "inspection.source") pure
