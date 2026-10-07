{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Recipe.Internal
  ( KnowledgeBase(..), RecipeType(..), RecipeDefinition(..), StoredRecipe(..)
  , storeRecipe, readRecipeState
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Text.JSON.Types (JSValue)
import Kyyn.Types.Curation (RecipeId(..))
import Kyyn.Types.KnowledgeBase (Recipe)
import Kyyn.Types.Diagnostic (errorDiagnostic)
import Kyyn.Types.Evolution (EvolutionFailure(..))
import Kyyn.Types.Fact (Fact)

-- | Domain facts together with separately identified, typed recipes.
data KnowledgeBase root = KnowledgeBase root [Fact StoredRecipe] deriving (Eq, Show)

-- The generated binding carries the inspected type's whole contract identity.
data RecipeType state = RecipeType Text Text
  (state -> JSValue) (JSValue -> Either String state)

-- | A recipe's instructions or flow and its typed state binding.
data RecipeDefinition state = RecipeDefinition Recipe (RecipeType state)

data StoredRecipe = StoredRecipe Recipe Text Text JSValue deriving (Eq, Show)

storeRecipe :: RecipeDefinition state -> state -> StoredRecipe
storeRecipe (RecipeDefinition method (RecipeType name identity encode _)) state =
  StoredRecipe method name identity (encode state)

readRecipeState :: RecipeId -> RecipeType state -> StoredRecipe
  -> Either EvolutionFailure state
readRecipeState (RecipeId ident) (RecipeType name identity _ decode)
    (StoredRecipe _ actualName actualIdentity value)
  | name /= actualName || identity /= actualIdentity = failure
      "recipe.state-type" ("Expected state type " <> name <> "; found " <> actualName <>
        ". Use the matching Before state binding to migrate this recipe.")
  | otherwise = either (failure "recipe.state-invalid" . Text.pack) Right (decode value)
  where
    failure code message = Left (EvolutionFailure
      [errorDiagnostic code ("Recipe " <> ident <> ": " <> message)])
