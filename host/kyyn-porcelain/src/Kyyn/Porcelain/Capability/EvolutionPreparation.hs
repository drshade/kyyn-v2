module Kyyn.Porcelain.Capability.EvolutionPreparation (prepareEvolution) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.Git (TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Root (SourceRoot(..), RootDefinition(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..))
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore, readWorkspace)
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadSourceAt, openCapturedSource)
import Kyyn.Porcelain.Capability.RootStore (rootLocation)

prepareEvolution :: (EvolutionStore :> es, RootOpening :> es)
  => EvolutionWorkspace -> Eff es (Either [Diagnostic] PreparedEvolution)
prepareEvolution location@(EvolutionWorkspace kb@(KnowledgeBase repository _) identity) = runExceptT $ do
  snapshot@(WorkspaceSnapshot (WorkspaceManifest revision _ _ _) beforeCopy target _ _) <- ExceptT (readWorkspace location)
  rootPath <- either (throwE . pure . errorDiagnostic "evolution.capture") pure (rootLocation kb)
  before@(SourceRoot contract _ (RootDefinition _ _ _ _ sources) _) <-
    ExceptT (loadSourceAt repository revision (Subtree rootPath))
  unless (beforeCopy == sources) (throwE [errorDiagnostic "evolution.before-mismatch"
    "before/ must match the selected revision's src/ tree; refresh it from that revision"])
  after <- ExceptT (openCapturedSource target)
  pure (PreparedEvolution (EvolutionContext kb identity (Before revision contract) snapshot) before after)
