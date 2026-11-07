{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Porcelain.Protocol.EvolutionPreparation (prepareEvolution, prepareEvolutionDescription, prepareEvolutionApi) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.Text as Text
import Data.List (stripPrefix, sort, nub)
import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.Git (TreePath(..), GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Root
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Domain.Contract (checkRootLayout, descriptionOf)
import Kyyn.Domain.Guest (CheckedGuest, InspectedSchema(..), checkedEntries)
import Kyyn.Domain.Recipe (RecipeDefinition(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionKind(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..), RecipeId(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.Contract (descriptionTypeName)
import qualified Kyyn.Types.Guest as G
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestInspection (GuestInspection, describeGuest)
import Kyyn.Plumbing.Protocol.EvolutionSources (captureEvolutionSources)
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore, readWorkspace)
import Kyyn.Porcelain.Capability.RootStore (RootStore, rootLocation, readRootDefinition, readRootRecipes)

-- Read accepted bytes without building their flake. Both endpoint schemas and
-- the referenced Before state types come from the target environment.
prepareEvolution :: (EvolutionStore :> es, RootStore :> es, Git.Git :> es, GuestCompilation :> es, GuestInspection :> es)
  => EvolutionWorkspace -> Eff es (Either [Diagnostic] PreparedEvolution)
prepareEvolution location = fmap (fmap fst) (prepareEvolutionDescription location)

prepareEvolutionDescription :: (EvolutionStore :> es, RootStore :> es, Git.Git :> es, GuestCompilation :> es, GuestInspection :> es)
  => EvolutionWorkspace -> Eff es (Either [Diagnostic] (PreparedEvolution,CheckedGuest))
prepareEvolutionDescription location@(EvolutionWorkspace kb identity) = runExceptT $ do
  (snapshot@(WorkspaceSnapshot (WorkspaceManifest revision _ _ _ _) _ target _ _),beforeCode,beforeDefinition,definitions,source) <-
    ExceptT (captureDescription location [])
  afterDefinition <- ExceptT (readRootDefinition target)
  program <- ExceptT (compileGuest source)
  guest <- ExceptT (describeGuest program)
  (beforeSchema,afterSchema,states) <- case [(before,after,states) |
      G.EvolutionDescriptionEntry before after states <- checkedEntries guest] of
    [description] -> pure description
    _ -> throwE [errorDiagnostic "evolution.description" "Expected one evolution description"]
  unless (sort (map fst states) == sort (nub [reference recipe | Fact _ recipe <- definitions]))
    (throwE [errorDiagnostic "evolution.description" "Evolution description differs from the selected Before state references"])
  beforeContract <- ExceptT (pure (checkRootLayout beforeSchema.contract))
  afterContract <- ExceptT (pure (checkRootLayout afterSchema.contract))
  contracts <- traverse (\(definition@(Fact _ recipe),state) -> do
    name <- case recipe of
      OpenRecipe _ authored -> pure authored
      ClosedRecipe _ -> Text.unpack <$> either (throwE . pure . errorDiagnostic "recipe.state-type" . Text.unpack) pure
        (descriptionTypeName (descriptionOf state.contract))
    pure (definition,name,state.contract))
    [(definition,state) | definition@(Fact _ recipe) <- definitions, (stateReference,state) <- states, stateReference == reference recipe]
  closure <- traverse (\path -> checked (relativePath
    (maybe (relativeName path) id (stripPrefix ".kyyn-before/" (relativeName path))))) beforeSchema.loadedSources
  let before = SourceRoot beforeContract beforeCode beforeDefinition closure
      after = SourceRoot afterContract target afterDefinition afterSchema.loadedSources
  pure (PreparedEvolution (EvolutionContext kb identity (Before revision beforeContract) snapshot) before after contracts,guest)
  where
    reference (OpenRecipe _ name) = OpenState (Text.pack name)
    reference (ClosedRecipe (FlowEntryRef name)) = ClosedFlow name
    checked = either (throwE . pure . errorDiagnostic "evolution.capture") pure

-- API discovery captures source context without validating either endpoint first.
-- The selected guest compiler decides which bindings the requested imports need.
prepareEvolutionApi :: (EvolutionStore :> es, RootStore :> es, Git.Git :> es, GuestCompilation :> es, GuestInspection :> es)
  => EvolutionWorkspace -> [Text.Text] -> Eff es (Either [Diagnostic] (GitRevision,CheckedGuest))
prepareEvolutionApi location modules = runExceptT $ do
  (WorkspaceSnapshot (WorkspaceManifest revision _ _ _ _) _ _ _ _,_,_,_,source) <- ExceptT (captureDescription location modules)
  program <- ExceptT (compileGuest source)
  guest <- ExceptT (describeGuest program)
  pure (revision,guest)

captureDescription :: (EvolutionStore :> es, RootStore :> es, Git.Git :> es)
  => EvolutionWorkspace -> [Text.Text]
  -> Eff es (Either [Diagnostic] (WorkspaceSnapshot,FileTree,RootDefinition,[Fact RecipeDefinition],GuestSources))
captureDescription location@(EvolutionWorkspace kb@(KnowledgeBase repository _) _) modules = runExceptT $ do
  snapshot@(WorkspaceSnapshot (WorkspaceManifest revision _ _ _ kind) beforeCopy target change _) <- ExceptT (readWorkspace location)
  rootPath <- checked (rootLocation kb)
  accepted <- ExceptT (Git.readTreeExcluding repository revision (Subtree rootPath) [factsLocation,recipeStatesLocation])
  beforeCode <- checked (fileTree [(path,bytes) | (path,bytes) <- files accepted, not (isRootMaterial path)])
  beforeDefinition@(RootDefinition beforeType beforeMetadata _ _ _ sources _) <- ExceptT (readRootDefinition beforeCode)
  unless (beforeCopy == sources) (throwE [errorDiagnostic "evolution.before-mismatch"
    "before/ must match the selected revision's src/ tree; refresh it from that revision"])
  definitions <- ExceptT (readRootRecipes accepted)
  selected <- case kind of
    AdHoc -> pure Nothing
    RecipeBased (RecipeId name) -> case [reference recipe | Fact (FactId actual) recipe <- definitions, actual == name] of
      [recipe] -> pure (Just recipe)
      _ -> throwE [errorDiagnostic "recipe.unknown" "The selected recipe must exist in Before"]
  source <- checked (captureEvolutionSources
    (EvolutionSelection (Text.pack beforeType) (Text.pack beforeMetadata) [reference recipe | Fact _ recipe <- definitions] selected (Just modules))
    beforeCopy target change)
  pure (snapshot,beforeCode,beforeDefinition,definitions,source)
  where
    reference (OpenRecipe _ name) = OpenState (Text.pack name)
    reference (ClosedRecipe (FlowEntryRef name)) = ClosedFlow name
    checked = either (throwE . pure . errorDiagnostic "evolution.capture") pure
