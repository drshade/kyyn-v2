{-# LANGUAGE ScopedTypeVariables, TypeApplications, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Runtime.EvolutionEntry (evolutionEntry) where

import Agentic.Aeson (fromAeson, toAeson)
import Kyyn.Contract
import Kyyn.Evolution (Evolution, KnowledgeBase)
import Kyyn.Evolution.Internal (evaluateEvolution)
import Kyyn.Types.Guest
import Kyyn.Types.SchemaMetadata (SchemaMetadata)
import Data.Text (Text)
import Kyyn.Runtime.Contract (runtimeCodec, toWire, fromWire)
import Kyyn.Runtime.Entry (Entry, pureEntry)
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
