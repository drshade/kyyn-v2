{-# LANGUAGE GADTs, OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Porcelain.Interpreter.WorkspaceApi (runWorkspaceApi) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Git (TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionKind(..))
import Kyyn.Domain.Root (factsLocation, recipeStatesLocation)
import Kyyn.Domain.Recipe (RecipeDefinition(..))
import Kyyn.Types.Fact (Fact(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Plumbing.Protocol.EvolutionSources (captureStoredEvolutionSources)
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Domain.Guest (checkedModules)
import Kyyn.Domain.GuestApi (WorkspaceCatalogue(..), ModuleDescription(..), ApiEntry(..), ApiOrigin(..), ApiSelection(..))
import Kyyn.Plumbing.Capability.Git (Git)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestInspection (GuestInspection, describeGuest)
import Kyyn.Porcelain.Protocol.EvolutionPreparation (prepareEvolutionDescription, prepareEvolutionApi)
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore, readWorkspace)
import Kyyn.Porcelain.Capability.RootStore (RootStore, rootLocation, readRootRecipes)
import Kyyn.Porcelain.Capability.WorkspaceApi (WorkspaceApi(..))

runWorkspaceApi :: (EvolutionStore :> es, RootStore :> es, Git :> es, GuestCompilation :> es, GuestInspection :> es)
  => Eff (WorkspaceApi : es) a -> Eff es a
runWorkspaceApi = interpret $ \_ operation -> case operation of
  InspectRootApi code selection -> runExceptT $ do
    let selected = case selection of
          ListApiModules -> Nothing
          InspectApiModule name -> Just (Text.pack name)
          InspectApiSymbol name -> Just (Text.pack name)
    source <- either (throwE . pure . errorDiagnostic "guest.workspace-sources") pure
      (guestSources (DiscoveryEntries (RootApi selected)) (files code))
    program <- ExceptT (compileGuest source)
    described <- ExceptT (describeGuest program)
    pure [ApiEntry (origin entry.moduleSource) entry | entry <- checkedModules described]
  InspectWorkspaceApi workspace@(EvolutionWorkspace kb@(KnowledgeBase repository _) _) selection -> runExceptT $ do
    WorkspaceSnapshot (WorkspaceManifest revision _ _ _ kind) _ target change _ <- ExceptT (readWorkspace workspace)
    let names = case selection of
          ListApiModules -> []
          InspectApiModule name -> [Text.pack name]
          InspectApiSymbol name -> [Text.pack name]
    case kind of
      AdHoc -> do
        path <- checked (rootLocation kb)
        accepted <- ExceptT (Git.readTreeExcluding repository revision (Subtree path) [factsLocation,recipeStatesLocation])
        definitions <- ExceptT (readRootRecipes accepted)
        let reference (OpenRecipe _ name) = OpenState (Text.pack name)
            reference (ClosedRecipe (FlowEntryRef name)) = ClosedFlow name
        source <- checked (captureStoredEvolutionSources [reference recipe | Fact _ recipe <- definitions] (Just names) target change)
        program <- ExceptT (compileGuest source)
        described <- ExceptT (describeGuest program)
        pure (WorkspaceCatalogue workspace revision (case selection of
          ListApiModules -> filter public (checkedModules described)
          _ -> checkedModules described))
      RecipeBased _ -> case selection of
        ListApiModules -> do
          (PreparedEvolution (EvolutionContext _ _ before _) _ _ _,described) <-
            ExceptT (prepareEvolutionDescription workspace)
          pure (WorkspaceCatalogue workspace (beforeRevision before) (filter public (checkedModules described)))
        _ -> do
          (base,described) <- ExceptT (prepareEvolutionApi workspace names)
          pure (WorkspaceCatalogue workspace base (checkedModules described))
  where
    checked value = either (throwE . pure . errorDiagnostic "evolution.capture") pure value
    origin path
      | Text.null path = SdkOrigin
      | ".kyyn-generated/" `Text.isPrefixOf` path = GeneratedOrigin
      | "plugins/" `Text.isPrefixOf` path = PluginOrigin
      | otherwise = KbOrigin
    public entry = "Kyyn.Workspace." `Text.isPrefixOf` entry.moduleName || entry.moduleName == "KyynFrozenProposal"
