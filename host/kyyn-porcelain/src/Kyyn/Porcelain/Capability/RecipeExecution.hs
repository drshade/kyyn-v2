{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RecipeExecution (RecipeExecution(..), executeRecipeFlow) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Root (Root)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Curation (RecipeId, PendingEvidence)
import Kyyn.Domain.Evidence (CurrentEvidence)
import Kyyn.Domain.FactProposal (FactProposal)
import Kyyn.Types.KnowledgeBase (FlowEntryRef)
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedPlugin)

data RecipeExecution :: Effect where
  ExecuteRecipeFlow :: Root -> [PreparedPlugin] -> FlowEntryRef -> RecipeId
    -> [(PendingEvidence,CurrentEvidence)] -> RecipeExecution m (Either [Diagnostic] FactProposal)
type instance DispatchOf RecipeExecution = Dynamic

executeRecipeFlow :: RecipeExecution :> es => Root -> [PreparedPlugin] -> FlowEntryRef -> RecipeId
  -> [(PendingEvidence,CurrentEvidence)] -> Eff es (Either [Diagnostic] FactProposal)
executeRecipeFlow root plugins entry recipe = send . ExecuteRecipeFlow root plugins entry recipe
