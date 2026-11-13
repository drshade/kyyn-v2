{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RecipeRunStore
  ( RecipeRunStore(..), RecipeRunWriter(..), withRecipeRun, appendRunEvent
  , listRecipeRuns, readRecipeRun, clearRecipeRun ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Numeric.Natural (Natural)
import Kyyn.Domain.RecipeRun
import Kyyn.Domain.Recipe (RecipeId)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)

-- Valid only for the dynamic extent of withRecipeRun. The interpreter owns IO.
data RecipeRunWriter = RecipeRunWriter KnowledgeBase RecipeRunHeader

data RecipeRunStore :: Effect where
  WithRecipeRun :: PreparedRecipeRun -> (RecipeRunWriter -> m a) -> RecipeRunStore m a
  AppendRunEvent :: RecipeRunWriter -> RunEventBody -> RecipeRunStore m RunEvent
  ListRecipeRuns :: KnowledgeBase -> Maybe RecipeId -> RecipeRunStore m [RecipeRunSummary]
  ReadRecipeRun :: KnowledgeBase -> RecipeRunId -> Maybe Natural -> Natural -> RecipeRunStore m RecipeRunPage
  ClearRecipeRun :: KnowledgeBase -> RecipeRunId -> RecipeRunStore m ()
type instance DispatchOf RecipeRunStore = Dynamic

withRecipeRun :: RecipeRunStore :> es => PreparedRecipeRun -> (RecipeRunWriter -> Eff es a) -> Eff es a
withRecipeRun prepared = send . WithRecipeRun prepared
appendRunEvent :: RecipeRunStore :> es => RecipeRunWriter -> RunEventBody -> Eff es RunEvent
appendRunEvent writer = send . AppendRunEvent writer
listRecipeRuns :: RecipeRunStore :> es => KnowledgeBase -> Maybe RecipeId -> Eff es [RecipeRunSummary]
listRecipeRuns kb = send . ListRecipeRuns kb
readRecipeRun :: RecipeRunStore :> es => KnowledgeBase -> RecipeRunId -> Maybe Natural -> Natural -> Eff es RecipeRunPage
readRecipeRun kb identity cursor = send . ReadRecipeRun kb identity cursor
clearRecipeRun :: RecipeRunStore :> es => KnowledgeBase -> RecipeRunId -> Eff es ()
clearRecipeRun kb = send . ClearRecipeRun kb
