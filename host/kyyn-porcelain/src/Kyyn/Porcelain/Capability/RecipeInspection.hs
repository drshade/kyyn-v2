{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RecipeInspection
  ( RecipeInspection(..), describeRecipe, describeRecipeAt ) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Text (Text)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Recipe (RecipeId)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Git (GitRevision, TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Recipe (DescriptionFormat, RecipeDefinition(..))
import Kyyn.Domain.Root (SourceRoot)
import Kyyn.Porcelain.Capability.Recipe (findRecipeAt)
import Kyyn.Porcelain.Capability.RecipeStore (RecipeStore)
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadSourceAt)
import Kyyn.Porcelain.Capability.RootStore (rootLocation)
import Kyyn.Types.Fact (Fact(..))
import Kyyn.Types.KnowledgeBase (Lifetime, FlowEntryRef)

data RecipeInspection :: Effect where
  DescribeRecipe :: SourceRoot -> Lifetime -> FlowEntryRef -> DescriptionFormat
    -> RecipeInspection m (Either [Diagnostic] Text)
type instance DispatchOf RecipeInspection = Dynamic

describeRecipe :: RecipeInspection :> es => SourceRoot -> Lifetime -> FlowEntryRef -> DescriptionFormat
  -> Eff es (Either [Diagnostic] Text)
describeRecipe source lifetime entry = send . DescribeRecipe source lifetime entry

describeRecipeAt :: (RecipeInspection :> es, RecipeStore :> es, RootOpening :> es)
  => KnowledgeBase -> GitRevision -> RecipeId -> DescriptionFormat
  -> Eff es (Either [Diagnostic] (Lifetime, FlowEntryRef, Text))
describeRecipeAt kb@(KnowledgeBase repository _) revision recipe format = runExceptT $ do
  Fact _ definition <- ExceptT (findRecipeAt kb revision recipe)
  (lifetime,entry) <- case definition of
    ClosedRecipe lifetime value -> pure (lifetime,value)
    OpenRecipe _ _ _ -> throwE [errorDiagnostic "recipe.open-agent"
      "Open-agent recipes have instructions, not a flow. Use root recipe show NAME to read them."]
  location <- either (throwE . pure . errorDiagnostic "kb.path") pure (rootLocation kb)
  source <- ExceptT (loadSourceAt repository revision (Subtree location))
  rendered <- ExceptT (describeRecipe source lifetime entry format)
  pure (lifetime,entry,rendered)
