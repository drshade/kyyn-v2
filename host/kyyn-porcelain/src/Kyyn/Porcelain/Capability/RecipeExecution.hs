{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RecipeExecution
  (RecipeExecution(..), PreparedRecipe(..), prepareRecipeFlow, executeRecipeFlow) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Data.Aeson (Value)
import Data.Text (Text)
import Kyyn.Domain.Root (Root)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Domain.Contract (RootContract, CheckedContract)
import Kyyn.Domain.FactProposal (FactProposal)
import Kyyn.Domain.CompiledEntry (CompiledEntry)
import Kyyn.Domain.Model (ModelConfiguration)
import Kyyn.Types.KnowledgeBase (FlowEntryRef)
import Kyyn.Porcelain.Capability.RecipeRunStore (RecipeRunWriter)
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedPlugin)

-- Preparation captures and validates every input before publishing a recording.
-- Execution uses the same immutable guest executable that supplied the graph.
data PreparedRecipe = PreparedRecipe
  { entry :: CompiledEntry, rootContract :: RootContract, stateContract :: CheckedContract
  , plugins :: [PreparedPlugin], model :: Maybe ModelConfiguration
  , arguments :: Value, graph :: Value, mermaid :: Text }

data RecipeExecution :: Effect where
  PrepareRecipeFlow :: Root -> FlowEntryRef -> CheckedValue -> Maybe Text
    -> RecipeExecution m (Either [Diagnostic] PreparedRecipe)
  ExecuteRecipeFlow :: RecipeRunWriter -> PreparedRecipe
    -> RecipeExecution m (Either [Diagnostic] FactProposal)
type instance DispatchOf RecipeExecution = Dynamic

prepareRecipeFlow :: RecipeExecution :> es => Root -> FlowEntryRef -> CheckedValue
  -> Maybe Text -> Eff es (Either [Diagnostic] PreparedRecipe)
prepareRecipeFlow root entry state = send . PrepareRecipeFlow root entry state

executeRecipeFlow :: RecipeExecution :> es => RecipeRunWriter -> PreparedRecipe
  -> Eff es (Either [Diagnostic] FactProposal)
executeRecipeFlow writer = send . ExecuteRecipeFlow writer
