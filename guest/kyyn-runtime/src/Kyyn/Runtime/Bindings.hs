{-# LANGUAGE ScopedTypeVariables, TypeApplications, OverloadedRecordDot #-}
-- Constructors used by compiler-generated modules, separate from the author SDK.
module Kyyn.Runtime.Bindings (collection, contractCodec, recipeType, inferredRecipeType, closedRecipe, rejectEvolution) where

import Kyyn.Types.StoredShape (storedShape)
import Data.Text (Text)
import Kyyn.Contract
import Kyyn.Types.Fact (Fact)
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Types.Guest (describeContract, DescribedContract(..))
import Kyyn.Optics (Lens')
import Kyyn.Edit.Internal (Collection(..))
import Kyyn.Evolution (RecipeType, RecipeDefinition)
import qualified Kyyn.Recipe.Internal as Recipe
import Kyyn.Types.KnowledgeBase (Recipe(ClosedAgent), FlowEntryRef(..))
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
  let description = describeContract compiled.description (SchemaMetadata [] [] []) []
      codec = runtimeCodec compiled.codec
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
  Recipe.RecipeDefinition (ClosedAgent (FlowEntryRef reference)) <$> recipeType @state name

-- A failed frozen decode has no successful observation or partial result.
rejectEvolution :: EvolutionFailure -> RecipeEvolution root state
rejectEvolution (EvolutionFailure diagnostics) = recipeEdit (Rationale mempty []) (refuse diagnostics)
