{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.Git (Repository(..), TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..), knowledgeBasePath)
import Kyyn.Domain.Path (relativePath, scopedPath, directoryScope)
import Kyyn.Domain.Root (SourceRoot(..), RootDefinition(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..))
import qualified Kyyn.Domain.Workspace as Workspace
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore(..))
import qualified Kyyn.Porcelain.Capability.RootOpening as RootOpening
import qualified Kyyn.Porcelain.Capability.WorkspaceStore as WorkspaceStore

runEvolutionStore
  :: (FileSystem.FileSystem :> es, WorkspaceStore.WorkspaceStore :> es, RootOpening.RootOpening :> es)
  => Eff (EvolutionStore : es) a -> Eff es a
runEvolutionStore = interpret $ \_ -> \case
  CaptureEvolution location@(EvolutionWorkspace kb@(KnowledgeBase repository _) identity) -> runExceptT $ do
    snapshot@(WorkspaceSnapshot (WorkspaceManifest revision _ _ _) beforeCopy _ _ _) <- readWorkspace location
    rootPath <- checked (relativePath "root" >>= knowledgeBasePath kb)
    SourceRoot contract _ (RootDefinition _ _ _ _ sources) <-
      ExceptT (RootOpening.loadSourceAt repository revision (Subtree rootPath))
    unless (beforeCopy == sources) (throwE [errorDiagnostic "evolution.before-mismatch"
      "before/ must match the selected revision's src/ tree; refresh it from that revision"])
    pure (CapturedEvolution (EvolutionContext kb identity (Before revision contract) snapshot))
  MatchesCapturedInputs (EvolutionContext kb identity _ captured) -> runExceptT $ do
    current <- readWorkspace (EvolutionWorkspace kb identity)
    pure (Workspace.matchesCapturedInputs captured current)

readWorkspace
  :: (FileSystem.FileSystem :> es, WorkspaceStore.WorkspaceStore :> es)
  => EvolutionWorkspace -> ExceptT [Diagnostic] (Eff es) WorkspaceSnapshot
readWorkspace (EvolutionWorkspace kb@(KnowledgeBase (Repository scope) _) identity) = do
  path <- checked (relativePath ("evolutions/" ++ evolutionIdName identity) >>= knowledgeBasePath kb)
  location <- checked (directoryScope (scopedPath scope path))
  tree <- ExceptT (Right <$> FileSystem.readTree location)
  ExceptT (WorkspaceStore.readWorkspaceSnapshot tree)

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "evolution.capture") pure
