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
import Kyyn.Domain.Root (SourceRoot(..), RootDefinition(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionState(Draft))
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import Kyyn.Plumbing.Protocol.Evolution (identityEvolutionSource)
import Kyyn.Porcelain.Capability.EvolutionAuthoring (EvolutionAuthoring(..))
import Kyyn.Porcelain.Capability.EvolutionPreparation (prepareEvolution)
import qualified Kyyn.Porcelain.Capability.EvolutionStore as EvolutionStore
import qualified Kyyn.Porcelain.Capability.RootOpening as RootOpening
import Kyyn.Porcelain.Capability.RootStore (rootLocation)
import qualified Kyyn.Porcelain.Capability.WorkspaceStore as WorkspaceStore

runEvolutionAuthoring
  :: (EvolutionStore.EvolutionStore :> es, RootOpening.RootOpening :> es,
      WorkspaceStore.WorkspaceStore :> es, FileSystem.FileSystem :> es)
  => Eff (EvolutionAuthoring : es) a -> Eff es a
runEvolutionAuthoring = interpret $ \_ -> \case
  CreateEvolution kb@(KnowledgeBase repository@(Repository scope) _) (EvolutionName name) revision -> runExceptT $ do
    rootPath <- checked (rootLocation kb)
    SourceRoot _ code (RootDefinition selected _ _ _ _ sources) _ <-
      ExceptT (RootOpening.loadSourceAt repository revision (Subtree rootPath))
    empty <- checked (fileTree [])
    entryPath <- checked (relativePath "Evolution.hs")
    change <- checked (fileTree [(entryPath,identityEvolutionSource selected)])
    tree <- ExceptT (WorkspaceStore.encodeWorkspaceSnapshot
      (WorkspaceSnapshot (WorkspaceManifest revision name "" Draft) sources code change empty))
    parentPath <- checked (relativePath "evolutions" >>= knowledgeBasePath kb)
    parent <- checked (directoryScope (scopedPath scope parentPath))
    entries <- ExceptT (Right <$> FileSystem.listDirectory parent)
    identity <- checked (nextEvolutionId
      [known | path <- maybe [] id entries, Right known <- [evolutionId (relativeName path)]] (EvolutionName name))
    allocated <- checked (relativePath (evolutionIdName identity))
    location <- checked (directoryScope (scopedPath parent allocated))
    ExceptT (Right <$> FileSystem.ensureDirectory parent)
    created <- ExceptT (Right <$> FileSystem.createDirectory location)
    unless created (throwE [errorDiagnostic "evolution.exists"
      (evolutionIdName identity ++ " already exists; create the evolution again with a new local sequence")])
    forM_ (files tree) $ \(path,bytes) -> ExceptT (Right <$> FileSystem.writeBytes location path bytes)
    pure (EvolutionWorkspace kb identity)
  CaptureEvolution location@(EvolutionWorkspace kb@(KnowledgeBase repository _) _) -> runExceptT $ do
    PreparedEvolution context@(EvolutionContext _ _ (Before revision _) _) before@(SourceRoot _ _ _ closure) after <-
      ExceptT (prepareEvolution location)
    rootPath <- checked (rootLocation kb)
    input <- ExceptT (RootOpening.loadRootMaterialAt repository revision (Subtree rootPath) before)
    pure (CapturedEvolution context input closure after)

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "evolution.capture") pure
