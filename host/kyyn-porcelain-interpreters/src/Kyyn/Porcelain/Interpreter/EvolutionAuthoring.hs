{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.EvolutionAuthoring (runEvolutionAuthoring) where

import Control.Monad (unless, forM_)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.FactProposal (FactProposal)
import Kyyn.Domain.Recipe (StoredRecipe(..))
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.Git (Repository(..), TreePath(..), GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..), knowledgeBasePath)
import Kyyn.Domain.Path (relativePath, relativeName, scopedPath, directoryScope)
import Kyyn.Domain.Root (Root(..), SourceRoot(..), RootDefinition(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionState(Draft), EvolutionKind(..))
import Kyyn.Types.Curation (RecipeId(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Protocol.FactProposal (proposalChange)
import Kyyn.Plumbing.Protocol.Evolution (identityEvolutionSource)
import Kyyn.Plumbing.Protocol.RecipeEvolution (identityRecipeEvolutionSource)
import Kyyn.Porcelain.Capability.EvolutionAuthoring (EvolutionAuthoring(..))
import Kyyn.Porcelain.Capability.EvolutionPreparation (prepareEvolution)
import qualified Kyyn.Porcelain.Capability.EvolutionStore as EvolutionStore
import qualified Kyyn.Porcelain.Capability.RootOpening as RootOpening
import Kyyn.Porcelain.Capability.RootStore (rootLocation)
import qualified Kyyn.Porcelain.Capability.WorkspaceStore as WorkspaceStore

runEvolutionAuthoring
  :: (EvolutionStore.EvolutionStore :> es, RootOpening.RootOpening :> es,
      WorkspaceStore.WorkspaceStore :> es, FileSystem.FileSystem :> es, DhallHandling :> es)
  => Eff (EvolutionAuthoring : es) a -> Eff es a
runEvolutionAuthoring = interpret $ \_ -> \case
  CreateEvolution kb name revision kind -> create kb name revision kind Nothing
  CreateFactProposal kb name revision recipe proposal -> create kb name revision (RecipeBased recipe) (Just proposal)
  CaptureEvolution location@(EvolutionWorkspace kb@(KnowledgeBase repository _) _) -> runExceptT $ do
    PreparedEvolution context@(EvolutionContext _ _ (Before revision _) _) before@(SourceRoot _ _ _ closure) after <-
      ExceptT (prepareEvolution location)
    rootPath <- checked (rootLocation kb)
    input <- ExceptT (RootOpening.loadRootMaterialAt repository revision (Subtree rootPath) before)
    pure (CapturedEvolution context input closure after)

create :: (RootOpening.RootOpening :> es, WorkspaceStore.WorkspaceStore :> es,
    FileSystem.FileSystem :> es, DhallHandling :> es)
  => KnowledgeBase -> EvolutionName -> GitRevision -> EvolutionKind -> Maybe FactProposal
  -> Eff es (Either [Diagnostic] EvolutionWorkspace)
create kb@(KnowledgeBase repository@(Repository scope) _) (EvolutionName name) revision kind proposal = runExceptT $ do
    rootPath <- checked (rootLocation kb)
    source@(SourceRoot contract code (RootDefinition selected _ _ _ _ sources) _) <-
      ExceptT (RootOpening.loadSourceAt repository revision (Subtree rootPath))
    stateContract <- case kind of
      AdHoc -> pure Nothing
      RecipeBased (RecipeId ident) -> do
        Root _ _ _ _ recipes <- ExceptT (RootOpening.loadRootMaterialAt repository revision (Subtree rootPath) source)
        case [state | Fact (FactId actual) (StoredRecipe _ _ state _) <- recipes, actual == ident] of
          [state] -> pure (Just state)
          _ -> throwE [errorDiagnostic "recipe.unknown" "The selected recipe must exist in Before"]
    empty <- checked (fileTree [])
    entryPath <- checked (relativePath "Evolution.hs")
    change <- case proposal of
      Nothing -> checked (fileTree [(entryPath,case kind of
        AdHoc -> identityEvolutionSource selected
        RecipeBased _ -> identityRecipeEvolutionSource selected)])
      Just value -> case stateContract of
        Just state -> ExceptT (proposalChange contract state value)
        Nothing -> checked (Left "Frozen proposals require a recipe-based workspace")
    tree <- ExceptT (WorkspaceStore.encodeWorkspaceSnapshot
      (WorkspaceSnapshot (WorkspaceManifest revision name "" Draft kind) sources code change empty))
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

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "evolution.capture") pure
