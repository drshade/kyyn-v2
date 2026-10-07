{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.WorkspaceApi (runWorkspaceApi) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (stripPrefix, isPrefixOf, sortOn)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.Git (TreePath(..))
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.GuestApi (WorkspaceCatalogue(..), ApiModule(..), ApiEntry(..), ApiOrigin(..), ApiSelection(..))
import Kyyn.Domain.Path (relativeName)
import Kyyn.Domain.Root (Root(..), SourceRoot(..), RootDefinition(..))
import qualified Kyyn.Domain.KnowledgeBase as KB
import Kyyn.Domain.Recipe (StoredRecipe(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionKind(..))
import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Plumbing.Capability.ApiInspection (ApiInspection, inspectApiModules)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection)
import Kyyn.Plumbing.Protocol.Evolution (evolutionBindings, mergeEvolutionSources)
import Kyyn.Plumbing.Protocol.RecipeEvolution (recipeEvolutionBindings)
import Kyyn.Plumbing.Protocol.FactProposal (lowerProposal)
import Kyyn.Porcelain.Capability.EvolutionPreparation (prepareEvolution)
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore)
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadRootMaterialAt)
import Kyyn.Porcelain.Capability.RootStore (rootLocation)
import Kyyn.Porcelain.Capability.Tool (ToolPreparation, prepareToolBindings)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation, preparePlugins)
import Kyyn.Porcelain.Capability.WorkspaceApi (WorkspaceApi(..))
import Kyyn.Porcelain.Protocol.RecipeBindings (prepareRecipeTypes)

runWorkspaceApi :: (EvolutionStore :> es, RootOpening :> es, ApiInspection :> es, SchemaInspection :> es, ToolPreparation :> es, PluginPreparation :> es, DhallHandling :> es)
  => FileTree -> Eff (WorkspaceApi : es) a -> Eff es a
runWorkspaceApi sdk = interpret $ \_ operation -> case operation of
  InspectRootApi (SourceRoot contract code _ _) selection -> runExceptT $ do
    plugins <- ExceptT (preparePlugins code)
    (toolSources,toolNames) <- ExceptT (prepareToolBindings code plugins)
    let names = toolNames ++ ["Kyyn.Workspace.FactEdits"]
    recipeBindings <- checked (evolutionBindings contract contract)
    sources <- checked (mergeEvolutionSources [toolSources,recipeBindings])
    let authored = sortOn id [map (\c -> if c == '/' then '.' else c) name |
          (path,_) <- files code, Just local <- [stripPrefix "src/" (relativeName path)],
          Just name <- [reverse <$> stripPrefix "sh." (reverse local)]]
        selected = case selection of
          ListApiModules -> []
          InspectApiModule name -> [name | name `elem` authored]
          InspectApiSymbol symbol -> take 1 (sortOn (negate . length)
            [name | name <- authored, (name ++ ".") `isPrefixOf` symbol])
        requested = case selection of
          ListApiModules -> names
          InspectApiModule name -> [name | name `elem` names] ++ selected
          InspectApiSymbol symbol -> take 1 (sortOn (negate . length)
            [name | name <- names, (name ++ ".") `isPrefixOf` symbol]) ++ selected
    inspected <- if null requested then pure [] else ExceptT (inspectApiModules sources requested)
    let entry origin name = ApiEntry origin (case [m | m@(ApiModule actual _ _) <- inspected, actual == name] of
          [m] -> m
          _ -> ApiModule name [] [])
    pure (map (entry GeneratedOrigin) names ++ map (entry KbOrigin) authored)
  InspectWorkspaceApi workspace -> runExceptT $ do
    PreparedEvolution (EvolutionContext kb@(KB.KnowledgeBase repository _) _ (Before revision _)
      (WorkspaceSnapshot (WorkspaceManifest _ _ _ _ kind) _ _ change _))
      beforeSource@(SourceRoot before _ (RootDefinition _ _ _ _ _ beforeSources) closure)
      afterSource@(SourceRoot after _ (RootDefinition _ _ _ _ _ afterSources) afterClosure) <- ExceptT (prepareEvolution workspace)
    (recipeBindings,recipeClosure,_,recipeNames) <- ExceptT (prepareRecipeTypes sdk beforeSources afterSource change)
    old <- checked (fileTree [(p,b) | (p,b) <- files beforeSources, p `elem` (closure ++ recipeClosure)])
    new <- checked (fileTree [(p,b) | (p,b) <- files afterSources, p `elem` afterClosure])
    (bindings,stateSources,stateContract) <- case kind of
      AdHoc -> do
        generated <- checked (evolutionBindings before after)
        empty <- checked (fileTree [])
        pure (generated,empty,Nothing)
      RecipeBased (RecipeId selected) -> do
        rootPath <- checked (rootLocation kb)
        Root _ _ _ recipes <- ExceptT (loadRootMaterialAt repository revision (Subtree rootPath) beforeSource)
        state <- checked $ case [(contract,value) | Fact (FactId name) (StoredRecipe _ _ contract value) <- recipes, name == selected] of
          [pair] -> Right pair
          _ -> Left "The selected recipe must exist in Before"
        generated <- checked (recipeEvolutionBindings before (fst state))
        pure (generated,beforeSources,Just state)
    lowered <- ExceptT (lowerProposal before after stateContract change)
    let hasProposal = any ((== "proposal.dhall") . relativeName . fst) (files change)
    frozen <- checked (fileTree [(p,b) | (p,b) <- files lowered,
      hasProposal, relativeName p == "KyynFrozenProposal.hs"])
    sources <- checked (mergeEvolutionSources [old,new,afterSources,stateSources,sdk,bindings,recipeBindings,frozen])
    modules <- ExceptT (inspectApiModules sources
      (["Kyyn.Workspace.Evolution", "Kyyn.Workspace.Before", "Kyyn.Workspace.After"]
        ++ recipeNames ++ ["KyynFrozenProposal" | not (null (files frozen))]))
    pure (WorkspaceCatalogue workspace revision modules)

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "guest.workspace-sources") pure
