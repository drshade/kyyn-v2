{-# LANGUAGE AllowAmbiguousTypes, ScopedTypeVariables, TypeApplications, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Runtime.EvolutionEntry (evolutionEntry, recipeEvolutionEntry, evolutionDescriptionEntry, describeState) where

import Agentic.Aeson (fromAeson, toAeson)
import Kyyn.Contract
import Kyyn.Evolution (Evolution, KnowledgeBase)
import Kyyn.Evolution.Internal (evaluateEvolution)
import Kyyn.Types.Guest
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Data.Text (Text)
import Kyyn.Runtime.Bindings (recipeCodec)
import Kyyn.Recipe (RecipeEvolution)
import Kyyn.Runtime.Contract (runtimeCodec, toWire, fromWire)
import Kyyn.Runtime.Entry (Entry(..), pureEntry)
import Kyyn.Types.GuestBuild (RecipeReference)
import Kyyn.Runtime.Evolution (knowledgeBaseCodec, evolutionReplyValue)
import qualified Kyyn.Runtime.Json as Wire

evolutionEntry :: forall before after. (Contract before, Contract after)
  => (SchemaMetadata,[Text]) -> (SchemaMetadata,[Text])
  -> Evolution (KnowledgeBase before) (KnowledgeBase after) -> Either ProjectionError Entry
evolutionEntry (beforeMetadata,beforeSources) (afterMetadata,afterSources) selected = do
  before <- compileContract (contract @before)
  after <- compileContract (contract @after)
  let contracts = AdHocContracts (describeContract before.description beforeMetadata beforeSources)
        (describeContract after.description afterMetadata afterSources)
      beforeCodec = knowledgeBaseCodec (runtimeCodec before.codec)
      afterCodec = knowledgeBaseCodec (runtimeCodec after.codec)
      run argument = do
        value <- Wire.decodeWith beforeCodec (toWire (fromAeson argument))
        reply <- evolutionReplyValue afterCodec (evaluateEvolution selected value)
        pure (toAeson (fromWire reply))
  pure (pureEntry (EvolutionEntry "Evolution.evolution" contracts) run)

recipeEvolutionEntry :: forall root state. (Contract root, Contract state)
  => (SchemaMetadata,[Text]) -> [Text]
  -> RecipeEvolution root state -> Either ProjectionError Entry
recipeEvolutionEntry (metadata,sources) stateSources selected = do
  root <- compileContract (contract @root)
  state <- compileContract (contract @state)
  let contracts = RecipeEvolutionContracts (describeContract root.description metadata sources)
        (describeContract state.description (SchemaMetadata [] [] []) stateSources)
      codec = recipeCodec (runtimeCodec root.codec) (runtimeCodec state.codec)
      run argument = do
        value <- Wire.decodeWith codec (toWire (fromAeson argument))
        reply <- evolutionReplyValue codec (evaluateEvolution selected value)
        pure (toAeson (fromWire reply))
  pure (pureEntry (EvolutionEntry "Evolution.evolution" contracts) run)

describeState :: forall state. Contract state => [Text] -> Either ProjectionError DescribedContract
describeState sources = do
  compiled <- compileContract (contract @state)
  pure (describeContract compiled.description (SchemaMetadata [] [] []) sources)

evolutionDescriptionEntry :: forall before after. (Contract before, Contract after)
  => (SchemaMetadata,[Text]) -> (SchemaMetadata,[Text])
  -> [(RecipeReference,Either ProjectionError DescribedContract)] -> Either ProjectionError Entry
evolutionDescriptionEntry (oldMetadata,oldSources) (newMetadata,newSources) states = do
  before <- compileContract (contract @before)
  after <- compileContract (contract @after)
  described <- traverse (\(reference,state) -> (reference,) <$> state) states
  pure (DescriptionEntry (EvolutionDescriptionEntry (describeContract before.description oldMetadata oldSources)
    (describeContract after.description newMetadata newSources) described))
