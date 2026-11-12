{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Recipe.Internal
  ( KnowledgeBase(..), RecipeType(..), RecipeDefinition(..), StoredRecipe(..), StoredDefinition(..), recipeMethod
  , storeRecipe, readRecipeState
  ) where

import Kyyn.Types.StoredShape (StoredShape)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Aeson (Value)
import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Kyyn.Types.KnowledgeBase (Recipe(OpenAgent, ClosedAgent), FlowEntryRef)
import Kyyn.Types.Diagnostic (errorDiagnostic)
import Kyyn.Types.Evolution (EvolutionFailure(..))
import Kyyn.Types.Fact (Fact)

-- | Domain facts together with separately identified, typed recipes.
data KnowledgeBase root = KnowledgeBase root [Fact StoredRecipe] deriving (Eq, Show)

-- | A generated binding identifying and encoding a recipe's state type.
data RecipeType state = RecipeType Text StoredShape
  (state -> Value) (Value -> Either String state)

-- | A recipe's instructions or flow and its typed state binding.
data RecipeDefinition state = RecipeDefinition Recipe (RecipeType state)

data StoredDefinition = OpenDefinition Text Text | ClosedDefinition FlowEntryRef deriving (Eq, Show)
data StoredRecipe = StoredRecipe StoredDefinition Value deriving (Eq, Show)

recipeMethod :: StoredDefinition -> Recipe
recipeMethod (OpenDefinition instructions _) = OpenAgent instructions
recipeMethod (ClosedDefinition flow) = ClosedAgent flow

storeRecipe :: RecipeDefinition state -> state -> StoredRecipe
storeRecipe (RecipeDefinition method (RecipeType name _ encode _)) state =
  StoredRecipe (case method of
    OpenAgent instructions -> OpenDefinition instructions name
    ClosedAgent flow -> ClosedDefinition flow) (encode state)

readRecipeState :: RecipeId -> RecipeType state -> StoredRecipe
  -> Either EvolutionFailure state
readRecipeState (RecipeId ident) (RecipeType _ _ _ decode)
    (StoredRecipe _ value) = either (failure "recipe.state-invalid" . Text.pack) Right (decode value)
  where
    failure code message = Left (EvolutionFailure
      [errorDiagnostic code ("Recipe " <> ident <> ": " <> message)])
