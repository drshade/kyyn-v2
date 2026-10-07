{-# LANGUAGE RankNTypes, OverloadedStrings #-}
module Kyyn.Evolution.KnowledgeBase
  ( KnowledgeBase, RecipeType, RecipeDefinition
  , facts, onFacts, openRecipe, unitRecipeType
  , createRecipe, updateRecipe, removeRecipe
  ) where

import Control.Monad.Trans.State.Strict (StateT(..))
import Data.Text (Text)
import Text.JSON.Types (JSValue(..), toJSObject, fromJSObject)
import Kyyn.Recipe.Internal
import Kyyn.Types.KnowledgeBase (Recipe(OpenAgent))
import Kyyn.Types.KnowledgeBase (RecipeId(..))
import Kyyn.Types.Diagnostic (errorDiagnostic)
import Kyyn.Types.Evolution (EvolutionFailure(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Edit (Edit)
import Kyyn.Optics (Lens, lens)

-- | Focus the domain facts, preserving recipes even when the facts type changes.
facts :: Lens (KnowledgeBase a) (KnowledgeBase b) a b
facts = lens (\(KnowledgeBase value _) -> value)
  (\(KnowledgeBase _ recipes) value -> KnowledgeBase value recipes)

-- | Apply a fallible domain transformation while keeping recipes unchanged.
onFacts :: (a -> Either EvolutionFailure b)
  -> KnowledgeBase a -> Either EvolutionFailure (KnowledgeBase b)
onFacts transform (KnowledgeBase value recipes) =
  (\after -> KnowledgeBase after recipes) <$> transform value

-- | Instructions for an open agent, with an explicit recipe state type.
openRecipe :: RecipeType state -> Text -> RecipeDefinition state
openRecipe state instructions = RecipeDefinition (OpenAgent instructions) state

-- | The state binding for a recipe that needs no remembered state.
unitRecipeType :: RecipeType ()
unitRecipeType = RecipeType "()"
  "3c0bb1f1944c4350562a169eb26598527e566911796d0d1338741cba74ac78de"
  (\() -> JSObject (toJSObject [])) decode
  where
    decode (JSObject fields) | null (fromJSObject fields) = Right ()
    decode _ = Left "Expected unit state"

-- | Create a recipe with its initial state. Refuses an existing recipe ID.
createRecipe :: RecipeId -> RecipeDefinition state -> state
  -> Edit (KnowledgeBase root) ()
createRecipe (RecipeId ident) definition state = StateT $ \(KnowledgeBase root recipes) ->
  if any (\(Fact (FactId name) _) -> name == ident) recipes
    then failure "recipe.duplicate" ident "Recipe already exists"
    else Right ((), KnowledgeBase root (recipes ++ [Fact (FactId ident) (storeRecipe definition state)]))

-- | Update a recipe's definition and state together, optionally migrating its
-- state type. An instruction-only change uses the same type and Right.
updateRecipe :: RecipeType before -> RecipeId -> RecipeDefinition after
  -> (before -> Either EvolutionFailure after) -> Edit (KnowledgeBase root) ()
updateRecipe before selected@(RecipeId ident) after transform = StateT $ \(KnowledgeBase root recipes) -> do
  old <- selectedRecipe selected recipes
  value <- readRecipeState selected before old >>= transform
  let changed = storeRecipe after value
  pure ((), KnowledgeBase root [if name == ident then Fact key changed else task |
    task@(Fact key@(FactId name) _) <- recipes])

-- | Remove a recipe and its state. Refuses a missing or ambiguous recipe ID.
removeRecipe :: RecipeId -> Edit (KnowledgeBase root) ()
removeRecipe selected@(RecipeId ident) = StateT $ \(KnowledgeBase root recipes) -> do
  _ <- selectedRecipe selected recipes
  pure ((), KnowledgeBase root [task | task@(Fact (FactId name) _) <- recipes, name /= ident])

selectedRecipe :: RecipeId -> [Fact StoredRecipe] -> Either EvolutionFailure StoredRecipe
selectedRecipe (RecipeId ident) recipes = case [value | Fact (FactId name) value <- recipes, name == ident] of
  [value] -> Right value
  [] -> failure "recipe.missing" ident "Recipe does not exist"
  _ -> failure "recipe.ambiguous" ident "More than one recipe has this ID"

failure :: Text -> Text -> Text -> Either EvolutionFailure a
failure code ident message = Left (EvolutionFailure
  [errorDiagnostic code ("Recipe " <> ident <> ": " <> message)])
