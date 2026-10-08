module Kyyn.Porcelain.Protocol.RecipeBindings (prepareRecipeTypes) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (nub, stripPrefix)
import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic, compilerContext)
import Kyyn.Domain.Contract (CheckedContract, checkContract, rootType, rootSchema)
import Kyyn.Domain.DataType (DataType(UnitType), haskellType)
import Kyyn.Domain.Root (SourceRoot(..), RootDefinition(..))
import Kyyn.Domain.Recipe (RecipeSignature(..))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (RelativePath)
import Kyyn.Domain.Plugin (qualifiedTypeName, bindingModule)
import qualified Kyyn.Plumbing.Capability.SchemaInspection as Schema
import Kyyn.Plumbing.Protocol.RecipeTypes (recipeTypeBinding, recipeFlowBindings)
import Kyyn.Plumbing.Protocol.Evolution (evolutionBindings, mergeEvolutionSources)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation, preparePlugins)
import Kyyn.Porcelain.Capability.Tool (ToolPreparation, prepareToolBindings)

-- Before's extra dependencies join the domain schema closure; After's complete
-- captured source tree is already available to the evolution compiler.
prepareRecipeTypes :: (Schema.SchemaInspection :> es, PluginPreparation :> es, ToolPreparation :> es)
  => FileTree -> FileTree -> SourceRoot -> FileTree
  -> Eff es (Either [Diagnostic] (FileTree, [RelativePath], [(String,CheckedContract)], [String]))
prepareRecipeTypes sdk before (SourceRoot schema code (RootDefinition _ _ _ _ _ after _) _) change = runExceptT $ do
  authored <- checked (fileTree (files after ++ files change))
  imports <- ExceptT (Schema.inspectImports authored)
  let requested = nub [(endpoint,selected) | (_,names) <- imports, name <- names,
        endpoint <- ["Before", "After"],
        Just selected <- [stripPrefix (prefix endpoint) name]]
  generated <- traverse (\(endpoint,selected) -> do
    name <- checked (qualifiedTypeName selected)
    sources <- checked (fileTree (files (if endpoint == "Before" then before else after) ++ files sdk))
    Schema.InspectedSchema contract closure <- ExceptT $ fmap
      (either (Left . map (compilerContext ("recipe state " ++ selected))) Right)
      (Schema.inspectType sources name)
    binding <- checked (recipeTypeBinding (prefix endpoint ++ selected) selected contract)
    pure (binding, if endpoint == "Before" then closure else [], (selected,contract))) requested
  let flowModules = nub [selected | (_,names) <- imports, name <- names,
        Just selected <- [stripPrefix flowPrefix name]]
  flowBindings <- if null flowModules then pure [] else do
    plugins <- ExceptT (preparePlugins code)
    (toolSources,_) <- ExceptT (prepareToolBindings code plugins)
    workspace <- checked (evolutionBindings schema schema)
    sources <- checked (mergeEvolutionSources [toolSources,workspace])
    traverse (\moduleName -> do
      exports <- ExceptT (Schema.inspectRecipeExports sources moduleName)
      contracts <- traverse (\(name,RecipeSignature _ _ state) -> do
        _ <- checked (bindingModule (moduleName ++ "." ++ name))
        contract <- ExceptT (pure (checkContract state (SchemaMetadata [] [] [])))
        pure (name,moduleName ++ "." ++ name,contract))
        [(name,signature) | (name,signature@(RecipeSignature domain _ _)) <- exports,
          domain == rootType (rootSchema schema)]
      binding <- checked (recipeFlowBindings (flowPrefix ++ moduleName) contracts)
      pure (binding,[(haskellType (rootType contract),contract) | (_,_,contract) <- contracts])) flowModules
  bindings <- checked (fileTree (concat [files binding | (binding,_,_) <- generated] ++
    concat [files binding | (binding,_) <- flowBindings]))
  unit <- ExceptT (pure (checkContract UnitType (SchemaMetadata [] [] [])))
  pure (bindings, nub (concat [closure | (_,closure,_) <- generated]),
    ("()",unit) : [contract | (_,_,contract) <- generated] ++ concatMap snd flowBindings,
    [prefix endpoint ++ name | (endpoint,name) <- requested] ++ map (flowPrefix ++) flowModules)
  where
    prefix endpoint = "Kyyn.Workspace." ++ endpoint ++ ".RecipeTypes."
    flowPrefix = "Kyyn.Workspace.After.RecipeFlows."
    checked = either (throwE . pure . errorDiagnostic "recipe.binding") pure
