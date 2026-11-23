{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, TypeApplications, OverloadedRecordDot #-}
-- Constructors used by compiler-generated modules, separate from the author SDK.
module Kyyn.Runtime.Bindings (collection, contractCodec, recipeType, inferredRecipeType, closedRecipe, interactiveFlow, rejectEvolution) where

import Kyyn.Types.StoredShape (storedShape)
import Data.Text (Text)
import Kyyn.Interactive.Internal (FlowRef(..))
import Kyyn.Contract
import Kyyn.Types.Fact (Fact)
import Kyyn.Optics (Lens')
import Kyyn.Edit.Internal (Collection(..))
import Kyyn.Evolution (RecipeType, RecipeDefinition)
import qualified Kyyn.Recipe.Internal as Recipe
import Kyyn.Types.KnowledgeBase (Lifetime(..), Recipe(ClosedAgent), FlowEntryRef(..))
import qualified Kyyn.Types.Contract as D
import Kyyn.Recipe (RecipeEvolution, recipeEdit)
import Kyyn.Edit (refuse)
import Kyyn.Types.Evolution (EvolutionFailure(..), Rationale(..))
import Kyyn.Runtime.Contract (runtimeCodec)
import qualified Kyyn.Runtime.Json as Wire

collection :: Text -> Lens' root [Fact value] -> Collection root value
collection = Collection

contractCodec :: forall value. Contract value => Either ProjectionError (Wire.Codec value)
contractCodec = runtimeCodec . (.codec) <$> compileContract (contract @value)

recipeType :: forall state. Contract state => Text -> Either ProjectionError (RecipeType state)
recipeType name = do
  compiled <- compileContract (contract @state)
  let codec = runtimeCodec compiled.codec
  shape <- either (Left . ProjectionError []) Right (storedShape compiled.description)
  pure (Recipe.RecipeType name shape (Wire.encodeWith codec) (Wire.decodeWith codec))

inferredRecipeType :: forall state. Contract state => Either ProjectionError (RecipeType state)
inferredRecipeType = do
  compiled <- compileContract (contract @state)
  name <- either (Left . ProjectionError []) Right (D.descriptionTypeName compiled.description)
  recipeType @state name

closedRecipe :: forall state. Contract state => Text -> Either ProjectionError (RecipeDefinition state)
closedRecipe reference = do
  compiled <- compileContract (contract @state)
  name <- either (Left . ProjectionError []) Right (D.descriptionTypeName compiled.description)
  Recipe.RecipeDefinition (ClosedAgent Ordinary (FlowEntryRef reference)) <$> recipeType @state name

-- A failed frozen decode has no successful observation or partial result.
rejectEvolution :: EvolutionFailure -> RecipeEvolution root state
rejectEvolution (EvolutionFailure diagnostics) = recipeEdit (Rationale mempty []) (refuse diagnostics)

interactiveFlow :: forall input output. (Contract input, Contract output)
  => Text -> Either ProjectionError (FlowRef input output)
interactiveFlow reference = do
  input <- compileWire (contract @input)
  output <- compileWire (contract @output)
  state <- recipeType @() "()"
  pure (FlowRef (Recipe.RecipeDefinition (ClosedAgent Interactive (FlowEntryRef reference)) state) input output)
