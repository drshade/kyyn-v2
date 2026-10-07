{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RootStore
  ( RootStore(..), readRootDefinition, checkRootValue, materializeRoot, loadRootValueForChecking
  , readExamples, encodeExample, exportRootFiles, readRootRecipes
  , readRecipeStates, encodeRootRecipes, checkRecipeValue, readCollection, rootLocation ) where

import Data.Aeson (Value)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Contract (RootContract, CheckedContract)
import Kyyn.Types.Fact (Fact)
import qualified Kyyn.Domain.Recipe as Value
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Root (Root, RootDefinition, CheckedValue)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Example (Example)
import Kyyn.Domain.Query (QueryDescriptor)
import Kyyn.Porcelain.Validated (Validated)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase, knowledgeBasePath)
import Kyyn.Domain.Path (RelativePath, relativePath)

rootLocation :: KnowledgeBase -> Either String RelativePath
rootLocation kb = relativePath "root" >>= knowledgeBasePath kb

data RootStore :: Effect where
  ReadRootDefinition :: FileTree -> RootStore m (Either [Diagnostic] RootDefinition)
  ReadRootRecipes :: FileTree -> RootStore m (Either [Diagnostic] [Fact Value.RecipeDefinition])
  ReadRecipeStates :: [(Fact Value.RecipeDefinition, String, CheckedContract)] -> FileTree
    -> RootStore m (Either [Diagnostic] [Fact Value.StoredRecipe])
  EncodeRootRecipes :: [Fact Value.StoredRecipe] -> RootStore m (Either [Diagnostic] FileTree)
  CheckRecipeValue :: CheckedContract -> Value -> RootStore m (Either [Diagnostic] CheckedValue)
  CheckRootValue :: RootContract -> Value -> RootStore m (Either [Diagnostic] CheckedValue)
  MaterializeRoot :: RootContract -> FileTree -> Value.KnowledgeBase CheckedValue Value.StoredRecipe -> RootStore m (Either [Diagnostic] Root)
  LoadRootValueForChecking :: Root -> RootStore m (Either [Diagnostic] CheckedValue)
  ReadCollection :: Validated Root -> String -> RootStore m (Either [Diagnostic] [Fact Value])
  ReadExamples :: Root -> [QueryDescriptor] -> RootStore m (Either [Diagnostic] [Example])
  EncodeExample :: Example -> RootStore m (Either [Diagnostic] FileTree)
  ExportRootFiles :: Validated Root -> RootStore m (Either [Diagnostic] FileTree)

type instance DispatchOf RootStore = Dynamic

readRootDefinition :: RootStore :> es => FileTree -> Eff es (Either [Diagnostic] RootDefinition)
readRootDefinition = send . ReadRootDefinition

readRootRecipes :: RootStore :> es => FileTree -> Eff es (Either [Diagnostic] [Fact Value.RecipeDefinition])
readRootRecipes = send . ReadRootRecipes

readRecipeStates :: RootStore :> es => [(Fact Value.RecipeDefinition, String, CheckedContract)] -> FileTree
  -> Eff es (Either [Diagnostic] [Fact Value.StoredRecipe])
readRecipeStates definitions = send . ReadRecipeStates definitions

encodeRootRecipes :: RootStore :> es => [Fact Value.StoredRecipe] -> Eff es (Either [Diagnostic] FileTree)
encodeRootRecipes = send . EncodeRootRecipes

checkRecipeValue :: RootStore :> es => CheckedContract -> Value -> Eff es (Either [Diagnostic] CheckedValue)
checkRecipeValue contract = send . CheckRecipeValue contract

checkRootValue :: RootStore :> es => RootContract -> Value -> Eff es (Either [Diagnostic] CheckedValue)
checkRootValue contract = send . CheckRootValue contract

materializeRoot :: RootStore :> es => RootContract -> FileTree -> Value.KnowledgeBase CheckedValue Value.StoredRecipe -> Eff es (Either [Diagnostic] Root)
materializeRoot contract code = send . MaterializeRoot contract code

loadRootValueForChecking :: RootStore :> es => Root -> Eff es (Either [Diagnostic] CheckedValue)
loadRootValueForChecking = send . LoadRootValueForChecking

readCollection :: RootStore :> es => Validated Root -> String -> Eff es (Either [Diagnostic] [Fact Value])
readCollection root = send . ReadCollection root

readExamples :: RootStore :> es => Root -> [QueryDescriptor] -> Eff es (Either [Diagnostic] [Example])
readExamples root = send . ReadExamples root

encodeExample :: RootStore :> es => Example -> Eff es (Either [Diagnostic] FileTree)
encodeExample = send . EncodeExample

exportRootFiles :: RootStore :> es => Validated Root -> Eff es (Either [Diagnostic] FileTree)
exportRootFiles = send . ExportRootFiles
