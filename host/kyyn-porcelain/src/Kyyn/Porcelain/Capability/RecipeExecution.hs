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

data RecipeExecution :: Effect where
  ExecuteRecipeFlow :: Root -> FlowEntryRef -> CheckedValue
    -> Maybe Text -> RecipeExecution m (Either [Diagnostic] FactProposal)
type instance DispatchOf RecipeExecution = Dynamic

executeRecipeFlow :: RecipeExecution :> es => Root -> FlowEntryRef -> CheckedValue
  -> Maybe Text -> Eff es (Either [Diagnostic] FactProposal)
executeRecipeFlow root entry state = send . ExecuteRecipeFlow root entry state
