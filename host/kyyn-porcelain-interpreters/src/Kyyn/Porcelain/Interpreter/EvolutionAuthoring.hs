{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.EvolutionAuthoring (runEvolutionAuthoring) where

import Control.Monad (unless, forM_)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.ByteString.Char8 as Bytes
import Kyyn.Porcelain.Protocol.InputTypes (scaffoldInputTypes)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.FactProposal (FactProposal)
import Kyyn.Domain.Recipe (StoredRecipe(..))
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.Git (Repository(..), TreePath(..), GitRevision, revisionName)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..), knowledgeBasePath)
import Kyyn.Domain.Path (relativePath, relativeName, scopedPath, directoryScope)
import Kyyn.Domain.Root (Root(..), SourceRoot(..), RootDefinition(..), isRootMaterial)
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionState(Draft), EvolutionKind(..))
import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Protocol.FactProposal (proposalChange)
import Kyyn.Plumbing.Protocol.Evolution (identityEvolutionSource)
import Kyyn.Plumbing.Protocol.RecipeEvolution (identityRecipeEvolutionSource)
import Kyyn.Porcelain.Capability.EvolutionAuthoring (EvolutionAuthoring(..))
import qualified Kyyn.Porcelain.Capability.EvolutionStore as EvolutionStore
import qualified Kyyn.Porcelain.Capability.RootOpening as RootOpening
import Kyyn.Porcelain.Capability.RootStore (RootStore, rootLocation, readRootDefinition)
import Kyyn.Plumbing.Capability.Git (Git)
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Porcelain.Protocol.StoredSnapshot (readStoredSnapshot)
import qualified Kyyn.Porcelain.Capability.WorkspaceStore as WorkspaceStore

runEvolutionAuthoring
  :: (RootStore :> es, Git :> es,
      EvolutionStore.EvolutionStore :> es, RootOpening.RootOpening :> es,
      WorkspaceStore.WorkspaceStore :> es, FileSystem.FileSystem :> es, DhallHandling :> es)
  => Eff (EvolutionAuthoring : es) a -> Eff es a
runEvolutionAuthoring = interpret $ \_ -> \case
  CreateEvolution kb name revision kind inputTypes -> create kb name revision kind Nothing inputTypes
  CreateFactProposal kb name revision recipe proposal -> create kb name revision (RecipeBased recipe) (Just proposal) False
  CaptureEvolution location@(EvolutionWorkspace kb@(KnowledgeBase repository _) identity) -> runExceptT $ do
    snapshot@(WorkspaceSnapshot (WorkspaceManifest revision _ _ _ kind) target _ _) <- ExceptT (EvolutionStore.readWorkspace location)
    rootPath <- checked (rootLocation kb)
    material <- ExceptT (Git.readTreeAt repository revision (Subtree rootPath))
    stored <- ExceptT (readStoredSnapshot material)
    code <- checked (fileTree [(path,bytes) | (path,bytes) <- files material, not (isRootMaterial path)])
    case kind of
      AdHoc -> pure ()
      RecipeBased _ -> unless (target == code) (throwE [errorDiagnostic "recipe.artifacts-changed"
        "Recipe-based evolutions preserve source and configuration; use an ad hoc evolution to change them"])
    pure (CapturedEvolution (EvolutionContext kb identity (Before revision) snapshot) stored code)

create :: (RootOpening.RootOpening :> es, RootStore :> es, Git :> es, WorkspaceStore.WorkspaceStore :> es,
    FileSystem.FileSystem :> es, DhallHandling :> es)
  => KnowledgeBase -> EvolutionName -> GitRevision -> EvolutionKind -> Maybe FactProposal -> Bool
  -> Eff es (Either [Diagnostic] EvolutionWorkspace)
create kb@(KnowledgeBase repository@(Repository scope) _) (EvolutionName name) revision kind proposal inputTypes = runExceptT $ do
    rootPath <- checked (rootLocation kb)
    empty <- checked (fileTree [])
    entryPath <- checked (relativePath "Evolution.hs")
    (code,change) <- case kind of
      AdHoc -> do
        material <- ExceptT (Git.readTreeAt repository revision (Subtree rootPath))
        stored <- ExceptT (readStoredSnapshot material)
        code <- checked (fileTree [(path,bytes) | (path,bytes) <- files material, not (isRootMaterial path)])
        RootDefinition selected _ _ _ _ _ _ <- ExceptT (readRootDefinition code)
        (helpers,notes) <- if inputTypes then ExceptT (pure (scaffoldInputTypes (revisionName revision) stored)) else pure (empty,[])
        notePath <- checked (relativePath "Input/README.md")
        let note = [(notePath,Bytes.pack (unlines ("# Stored input types" : "" : notes))) | inputTypes]
        change <- checked (fileTree ((entryPath,identityEvolutionSource selected) : files helpers ++ note))
        pure (code,change)
      RecipeBased (RecipeId ident) -> do
        unless (not inputTypes) (throwE [errorDiagnostic "evolution.input-types" "--input-types applies to ad hoc evolutions"] )
        source@(SourceRoot contract code (RootDefinition selected _ _ _ _ _ _) _) <-
          ExceptT (RootOpening.loadSourceAt repository revision (Subtree rootPath))
        Root _ _ _ recipes <- ExceptT (RootOpening.loadRootMaterialAt repository revision (Subtree rootPath) source)
        state <- case [state | Fact (FactId actual) (StoredRecipe _ _ state _) <- recipes, actual == ident] of
          [state] -> pure state
          _ -> throwE [errorDiagnostic "recipe.unknown" "The selected recipe must exist in Before"]
        change <- case proposal of
          Nothing -> checked (fileTree [(entryPath,identityRecipeEvolutionSource selected)])
          Just value -> ExceptT (proposalChange contract state value)
        pure (code,change)
    tree <- ExceptT (WorkspaceStore.encodeWorkspaceSnapshot
      (WorkspaceSnapshot (WorkspaceManifest revision name "" Draft kind) code change empty))
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
