{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (partition)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Contract (checkRootLayout)
import Kyyn.Domain.Root (Root(..), SourceRoot(..), RootDefinition(..), factsLocation, isFactPath, isRootMaterial, recipesLocation, recipeStatesLocation)
import Kyyn.Domain.Recipe (StoredRecipe)
import Kyyn.Types.Fact (Fact)
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (RelativePath, relativePath, relativeName)
import Kyyn.Domain.Git (TreePath(..))
import qualified Kyyn.Plumbing.Capability.Git as Git
import qualified Kyyn.Plumbing.Capability.SchemaInspection as Schema
import Kyyn.Porcelain.Capability.RootOpening (RootOpening(..))
import Kyyn.Porcelain.Capability.RootStore (RootStore, readRootDefinition, loadRootValueForChecking, readRootRecipes, readRecipeStates)
import Kyyn.Porcelain.Capability.Tool (ToolPreparation)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation)
import Kyyn.Porcelain.Protocol.RecipeContracts (inspectRecipeContracts)

runRootOpening
  :: (Schema.SchemaInspection :> es, Git.Git :> es, RootStore :> es, ToolPreparation :> es, PluginPreparation :> es)
  => FileTree -> Eff (RootOpening : es) a -> Eff es a
runRootOpening sdk = interpret $ \_ -> \case
  OpenCapturedSource tree -> openSource sdk tree
  LoadSourceAt repository revision prefix -> do
    captured <- Git.readTreeExcluding repository revision prefix [factsLocation, recipesLocation, recipeStatesLocation]
    either (pure . Left) (openSource sdk) captured
  OpenCapturedRoot tree -> openTree sdk tree
  LoadRootAt repository revision prefix -> do
    captured <- Git.readTreeAt repository revision prefix
    either (pure . Left) (openTree sdk) captured
  LoadRootMaterialAt repository revision prefix source@(SourceRoot contract code _ _) -> runExceptT $ do
    location <- checked (relativePath (case prefix of
      WholeTree -> relativeName factsLocation
      Subtree path -> relativeName path ++ "/" ++ relativeName factsLocation))
    present <- ExceptT (Git.readDirectoryAt repository revision (Subtree location))
    entries <- case present of
      Nothing -> pure []
      Just _ -> do
        tree <- ExceptT (Git.readTreeAt repository revision (Subtree location))
        traverse (\(p,b) -> do
          path <- checked (relativePath (relativeName factsLocation ++ "/" ++ relativeName p))
          pure (path,b)) (files tree)
    facts <- checked (fileTree entries)
    recipePath <- checked (relativePath (case prefix of
      WholeTree -> relativeName recipesLocation
      Subtree path -> relativeName path ++ "/" ++ relativeName recipesLocation))
    recipeBytes <- ExceptT (Git.readFileAt repository revision recipePath)
    statePath <- checked (relativePath (case prefix of
      WholeTree -> relativeName recipeStatesLocation
      Subtree path -> relativeName path ++ "/" ++ relativeName recipeStatesLocation))
    presentStates <- ExceptT (Git.readDirectoryAt repository revision (Subtree statePath))
    stateEntries <- case presentStates of
      Nothing -> pure []
      Just _ -> do
        tree <- ExceptT (Git.readTreeAt repository revision (Subtree statePath))
        traverse (\(p,b) -> do
          path <- checked (relativePath (relativeName recipeStatesLocation ++ "/" ++ relativeName p))
          pure (path,b)) (files tree)
    recipeTree <- checked (fileTree (maybe [] (\bytes -> [(recipesLocation,bytes)]) recipeBytes ++ stateEntries))
    recipes <- ExceptT (loadRecipes sdk source recipeTree)
    pure (Root contract facts code recipes)

openTree
  :: (Schema.SchemaInspection :> es, RootStore :> es, ToolPreparation :> es, PluginPreparation :> es)
  => FileTree -> FileTree -> Eff es (Either [Diagnostic] Root)
openTree sdk tree = runExceptT $ do
  (root,_) <- ExceptT (openInput sdk tree)
  _ <- ExceptT (loadRootValueForChecking root)
  pure root

openInput
  :: (Schema.SchemaInspection :> es, RootStore :> es, ToolPreparation :> es, PluginPreparation :> es)
  => FileTree -> FileTree -> Eff es (Either [Diagnostic] (Root, [RelativePath]))
openInput sdk tree = runExceptT $ do
  source@(SourceRoot contract code _ closure) <- ExceptT (openSource sdk tree)
  facts <- checked (fileTree [(p,b) | (p,b) <- files tree, isFactPath p])
  recipes <- ExceptT (loadRecipes sdk source tree)
  pure (Root contract facts code recipes, closure)

loadRecipes :: (Schema.SchemaInspection :> es, RootStore :> es, ToolPreparation :> es, PluginPreparation :> es)
  => FileTree -> SourceRoot -> FileTree -> Eff es (Either [Diagnostic] [Fact StoredRecipe])
loadRecipes sdk source tree = runExceptT $ do
  definitions <- ExceptT (readRootRecipes tree)
  contracts <- ExceptT (inspectRecipeContracts sdk source definitions)
  ExceptT (readRecipeStates contracts tree)

openSource
  :: (Schema.SchemaInspection :> es, RootStore :> es)
  => FileTree -> FileTree -> Eff es (Either [Diagnostic] SourceRoot)
openSource sdk tree = runExceptT $ do
  definition@(RootDefinition typeName metadataName _ _ _ authored _) <- ExceptT (readRootDefinition tree)
  source <- checked (Schema.schemaSource (files authored ++ files sdk) typeName metadataName)
  Schema.InspectedSchema inspected closure <- ExceptT (Schema.inspectSchema source)
  contract <- ExceptT (pure (checkRootLayout inspected))
  let (_, codeEntries) = partition (isRootMaterial . fst) (files tree)
  code <- checked (fileTree codeEntries)
  pure (SourceRoot contract code definition closure)

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "root.opening") pure
