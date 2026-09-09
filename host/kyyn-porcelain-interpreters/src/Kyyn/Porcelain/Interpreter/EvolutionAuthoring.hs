{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.EvolutionAuthoring (runEvolutionAuthoring) where

import Control.Monad (unless, forM_)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.Git (Repository(..), TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..), knowledgeBasePath)
import Kyyn.Domain.Path (relativePath, relativeName, scopedPath, directoryScope)
import Kyyn.Domain.Root (Root(..), SourceRoot(..), RootDefinition(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionState(Draft))
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import Kyyn.Plumbing.Protocol.Evolution (identityEvolutionSource)
import Kyyn.Porcelain.Capability.EvolutionAuthoring (EvolutionAuthoring(..))
import qualified Kyyn.Porcelain.Capability.EvolutionStore as EvolutionStore
import qualified Kyyn.Porcelain.Capability.RootOpening as RootOpening
import Kyyn.Porcelain.Capability.RootStore (RootStore, rootLocation, readRootDefinition)
import qualified Kyyn.Porcelain.Capability.WorkspaceStore as WorkspaceStore

runEvolutionAuthoring
  :: (EvolutionStore.EvolutionStore :> es, RootOpening.RootOpening :> es,
      WorkspaceStore.WorkspaceStore :> es, FileSystem.FileSystem :> es, RootStore :> es)
  => Eff (EvolutionAuthoring : es) a -> Eff es a
runEvolutionAuthoring = interpret $ \_ -> \case
  CreateEvolution kb@(KnowledgeBase repository@(Repository scope) _) (EvolutionName name) revision -> runExceptT $ do
    rootPath <- checked (rootLocation kb)
    SourceRoot _ code (RootDefinition selected _ _ _ sources) _ <-
      ExceptT (RootOpening.loadSourceAt repository revision (Subtree rootPath))
    empty <- checked (fileTree [])
    entryPath <- checked (relativePath "Evolution.hs")
    change <- checked (fileTree [(entryPath,identityEvolutionSource selected)])
    tree <- ExceptT (WorkspaceStore.encodeWorkspaceSnapshot
      (WorkspaceSnapshot (WorkspaceManifest revision name "" Draft) sources code change empty))
    parentPath <- checked (relativePath "evolutions" >>= knowledgeBasePath kb)
    parent <- checked (directoryScope (scopedPath scope parentPath))
    allocated <- ExceptT (Right <$> FileSystem.createUniqueDirectory parent)
    identity <- checked (evolutionId (relativeName allocated))
    location <- checked (directoryScope (scopedPath parent allocated))
    forM_ (files tree) $ \(path,bytes) -> ExceptT (Right <$> FileSystem.writeBytes location path bytes)
    pure (EvolutionWorkspace kb identity)
  CaptureEvolution location@(EvolutionWorkspace kb@(KnowledgeBase repository _) identity) -> runExceptT $ do
    snapshot@(WorkspaceSnapshot (WorkspaceManifest revision _ _ _) beforeCopy _ _ _) <- ExceptT (EvolutionStore.readWorkspace location)
    rootPath <- checked (rootLocation kb)
    (input@(Root contract _ code),closure) <- ExceptT (RootOpening.loadRootInputAt repository revision (Subtree rootPath))
    RootDefinition _ _ _ _ sources <- ExceptT (readRootDefinition code)
    unless (beforeCopy == sources) (throwE [errorDiagnostic "evolution.before-mismatch"
      "before/ must match the selected revision's src/ tree; refresh it from that revision"])
    pure (CapturedEvolution (EvolutionContext kb identity (Before revision contract) snapshot)
      input closure)

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "evolution.capture") pure
