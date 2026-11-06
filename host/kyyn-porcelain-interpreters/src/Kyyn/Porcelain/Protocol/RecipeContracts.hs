{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Porcelain.Protocol.RecipeContracts (inspectRecipeContracts) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Contract (CheckedContract, rootSchema, rootType, contractId)
import Kyyn.Domain.DataType (haskellType)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Guest (InspectedSchema(..), checkedEntries)
import Kyyn.Domain.Recipe (RecipeDefinition(..), checkRecipeDefinitions)
import Kyyn.Domain.Root (SourceRoot(..))
import Kyyn.Types.Fact (Fact(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import qualified Kyyn.Types.Guest as G
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest, guestSources, GuestSelection(..), RecipeReference(..))
import Kyyn.Plumbing.Capability.GuestInspection (GuestInspection, describeGuest)

inspectRecipeContracts :: (GuestCompilation :> es, GuestInspection :> es)
  => SourceRoot -> [Fact RecipeDefinition]
  -> Eff es (Either [Diagnostic] [(Fact RecipeDefinition, String, CheckedContract)])
inspectRecipeContracts (SourceRoot schema code _ _) definitions = runExceptT $ do
  _ <- ExceptT (pure (checkRecipeDefinitions definitions))
  if null definitions then pure [] else do
    let references = [case definition of
          OpenRecipe _ name -> OpenState (Text.pack name)
          ClosedRecipe (FlowEntryRef name) -> ClosedFlow name | Fact _ definition <- definitions]
    source <- either (throwE . pure . errorDiagnostic "recipe.sources") pure (guestSources (RecipeEntries references) (files code))
    program <- ExceptT (compileGuest source)
    description <- ExceptT (describeGuest program)
    traverse (\definition@(Fact _ method) -> case method of
      OpenRecipe _ name -> case [selected.contract | G.ContractEntry actual selected <- checkedEntries description,
          actual == "$state." <> Text.pack name] of
        [contract] -> pure (definition,name,contract)
        _ -> missing name
      ClosedRecipe (FlowEntryRef reference) -> case [(root.contract,state.contract) |
          G.RecipeEntry _ actual (G.RecipeContracts root _ state) <- checkedEntries description, actual == reference] of
        [(root,contract)] -> do
          unless (contractId root == contractId (rootSchema schema)) (throwE
            [errorDiagnostic "recipe.root-type" "Recipe flow takes a different Root contract"])
          pure (definition,haskellType (rootType contract),contract)
        _ -> missing (Text.unpack reference)) definitions
  where
    missing name = throwE [errorDiagnostic "recipe.description" ("Guest did not describe recipe reference " ++ name)]
