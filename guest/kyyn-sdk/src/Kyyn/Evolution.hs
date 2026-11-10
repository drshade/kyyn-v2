{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Evolution
  ( Evolution, TargetEdits, prepare, edit, identityEvolution, module Kyyn.Evolution.Preparation, Rationale(..), EvolutionFailure(..)
  , EvidenceRef(..), EvidenceId(..), RecipeId(..)
  , KnowledgeBase, RecipeType, RecipeDefinition, facts, onFacts
  , openRecipe, unitRecipeType, createRecipe, updateRecipe, removeRecipe
  , module Kyyn.Edit
  ) where

import Kyyn.Types.Evolution (Rationale(..), EvolutionFailure(..))
import Kyyn.Types.Evidence (EvidenceRef(..), EvidenceId(..))
import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Kyyn.Evolution.Target (Evolution, TargetEdits, prepare, edit, identityEvolution)
import Kyyn.Evolution.Preparation (Preparation, TargetField, readCollection, migrateCollection, renameCollection, removeCollection, removeFact, readField, migrateField, putField, renameField, removeField, readRecipeState, migrateRecipe, retireRecipe)
import Kyyn.Evolution.KnowledgeBase
import Kyyn.Edit

