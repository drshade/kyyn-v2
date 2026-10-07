{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RecipeExecution (RecipeExecution(..), executeRecipeFlow) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Root (Root)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Data.Text (Text)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Domain.FactProposal (FactProposal)
import Kyyn.Types.KnowledgeBase (FlowEntryRef)
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedPlugin)

data RecipeExecution :: Effect where
  ExecuteRecipeFlow :: Root -> [PreparedPlugin] -> FlowEntryRef -> CheckedValue
    -> Maybe Text -> RecipeExecution m (Either [Diagnostic] FactProposal)
type instance DispatchOf RecipeExecution = Dynamic

executeRecipeFlow :: RecipeExecution :> es => Root -> [PreparedPlugin] -> FlowEntryRef -> CheckedValue
  -> Maybe Text -> Eff es (Either [Diagnostic] FactProposal)
executeRecipeFlow root plugins entry state = send . ExecuteRecipeFlow root plugins entry state
