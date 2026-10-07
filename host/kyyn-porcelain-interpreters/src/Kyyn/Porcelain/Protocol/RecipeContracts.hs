module Kyyn.Porcelain.Protocol.RecipeContracts (inspectRecipeContracts) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Contract (CheckedContract, rootSchema, rootType, checkContract)
import Kyyn.Domain.DataType (DataType(UnitType), haskellType)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Plugin (qualifiedTypeName)
import Kyyn.Domain.Recipe (RecipeDefinition(..), RecipeSignature(..), checkRecipeDefinitions)
import Kyyn.Domain.Root (SourceRoot(..), RootDefinition(..))
import Kyyn.Types.Fact (Fact(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import qualified Kyyn.Plumbing.Capability.SchemaInspection as Schema
import Kyyn.Plumbing.Protocol.Evolution (evolutionBindings, mergeEvolutionSources)
import Kyyn.Porcelain.Capability.Tool (ToolPreparation, prepareToolBindings)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation, preparePlugins)

inspectRecipeContracts :: (Schema.SchemaInspection :> es, ToolPreparation :> es, PluginPreparation :> es)
  => FileTree -> SourceRoot -> [Fact RecipeDefinition]
  -> Eff es (Either [Diagnostic] [(Fact RecipeDefinition, String, CheckedContract)])
inspectRecipeContracts sdk (SourceRoot schema code (RootDefinition _ _ _ _ _ authored) _) definitions = runExceptT $ do
  _ <- ExceptT (pure (checkRecipeDefinitions definitions))
  base <- checked (fileTree (files authored ++ files sdk))
  flowSources <- if null [() | Fact _ (ClosedRecipe _) <- definitions] then pure base else do
    plugins <- ExceptT (preparePlugins code)
    (sources,_) <- ExceptT (prepareToolBindings code plugins)
    bindings <- checked (evolutionBindings schema schema)
    checked (mergeEvolutionSources [sources,bindings])
  traverse (\definition@(Fact _ method) -> case method of
    OpenRecipe _ "()" -> do
      contract <- ExceptT (pure (checkContract UnitType (SchemaMetadata [] [] [])))
      pure (definition,"()",contract)
    OpenRecipe _ name -> do
      selected <- checked (qualifiedTypeName name)
      Schema.InspectedSchema contract _ <- ExceptT (Schema.inspectType base selected)
      pure (definition,name,contract)
    ClosedRecipe (FlowEntryRef entry) -> do
      RecipeSignature root _ state <- ExceptT (Schema.inspectRecipeFunction flowSources (Text.unpack entry))
      unless (root == rootType (rootSchema schema)) (throwE
        [errorDiagnostic "recipe.root-type" "Recipe flow takes a different root type"])
      contract <- ExceptT (pure (checkContract state (SchemaMetadata [] [] [])))
      pure (definition,haskellType state,contract)) definitions
  where
    checked = either (throwE . pure . errorDiagnostic "recipe.state-contract") pure
