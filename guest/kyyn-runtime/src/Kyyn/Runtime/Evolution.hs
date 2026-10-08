{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs, EmptyDataDecls, EmptyCase #-}
module Kyyn.Runtime.Evolution (NoRequests, executeEvolution, encodeEvolutionReply, knowledgeBaseCodec) where

import Kyyn.Evolution.Internal (EvolutionOutput(..), StepObservation(..), RecordedRoot(..))
import Kyyn.Types.Evolution (EvolutionFailure(..), Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Evidence (EvidenceId(..))
import Kyyn.Types.KnowledgeBase (Recipe(..), FlowEntryRef(..))
import Kyyn.Recipe.Internal (KnowledgeBase(..), StoredRecipe(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.Diagnostic (ValidationReport(..))
import Kyyn.Types.Program (Program(..))
import Kyyn.Runtime.Json
import Kyyn.Runtime.Validation (encodeReportValue)
import Text.JSON.Types (JSValue(JSArray))

data NoRequests a

knowledgeBaseCodec :: Codec a -> Codec (KnowledgeBase a)
knowledgeBaseCodec valueCodec = Codec encode decode
  where
    encode (KnowledgeBase value recipes) = record
      [("facts", encodeWith valueCodec value), ("recipes", encodeWith (listCodec recipeCodec) recipes)]
    decode value = do
      values <- fields ["facts","recipes"] value
      KnowledgeBase <$> field "facts" valueCodec values <*> field "recipes" (listCodec recipeCodec) values
    recipeCodec = Codec encodeRecipe decodeRecipe
    encodeRecipe (Fact (FactId name) payload) = record
      [("id",encodeWith textCodec name),
       ("value",encodeStored payload)]
    decodeRecipe value = do
      values <- fields ["id","value"] value
      name <- field "id" textCodec values
      payload <- field "value" payloadCodec values
      pure (Fact (FactId name) payload)
    payloadCodec = Codec encodeStored decodeStored
    encodeStored (StoredRecipe method stateType contract state) = record
      [("method",encodePayload method),("stateType",encodeWith textCodec stateType),
       ("stateContract",encodeWith textCodec contract),("state",state)]
    decodeStored value = do
      values <- fields ["method","stateType","stateContract","state"] value
      StoredRecipe <$> field "method" (Codec encodePayload decodePayload) values
        <*> field "stateType" textCodec values <*> field "stateContract" textCodec values
        <*> field "state" (Codec id Right) values
    encodePayload (OpenAgent instructions) = tagged "OpenAgent" (Just
      (record [("instructions",encodeWith textCodec instructions)]))
    encodePayload (ClosedAgent (FlowEntryRef entry)) = tagged "ClosedAgent" (Just
      (record [("flow",encodeWith textCodec entry)]))
    decodePayload value = do
      (name, payload) <- variant value
      case (name,payload) of
        ("OpenAgent", Just contents) -> do
          values <- fields ["instructions"] contents
          OpenAgent <$> field "instructions" textCodec values
        ("ClosedAgent", Just contents) -> do
          values <- fields ["flow"] contents
          ClosedAgent . FlowEntryRef <$> field "flow" textCodec values
        _ -> Left "Expected OpenAgent or ClosedAgent recipe"

executeEvolution :: Codec a -> Codec b
  -> (a -> Program NoRequests (Either EvolutionFailure (EvolutionOutput b)))
  -> String -> Either String JSValue
executeEvolution beforeCodec afterCodec selected input = do
  before <- parseValue input >>= decodeWith beforeCodec
  case selected before of
    Pure result -> evolutionReplyValue afterCodec result
    Request operation _ -> case operation of {}

encodeEvolutionReply :: Codec a -> Either EvolutionFailure (EvolutionOutput a) -> Either String String
encodeEvolutionReply codec result = evolutionReplyValue codec result >>= printValue

evolutionReplyValue :: Codec a -> Either EvolutionFailure (EvolutionOutput a) -> Either String JSValue
evolutionReplyValue codec result = do
  value <- case result of
    Left (EvolutionFailure diagnostics) -> do
      report <- encodeReportValue (ValidationReport diagnostics)
      pure (tagged "Rejected" (Just report))
    Right (EvolutionOutput output steps) -> pure (tagged "Succeeded" (Just (record
      [("after", encodeWith codec output), ("steps", JSArray (map encodeStep steps))])))
  pure value
  where
    text = encodeWith textCodec
    encodeRoot (RecordedRoot contract value) = record [("contract",text contract),("value",value)]
    encodeStep (StepObservation rationale before after) = record
      [("rationale",encodeRationale rationale),("before",encodeRoot before),("after",encodeRoot after)]
    encodeRationale (Rationale explanation evidence) = record
      [("explanation",text explanation),("evidence",JSArray (map encodeEvidence evidence))]
    encodeEvidence (EvidenceRef producer connector source references) = record
      [("producer",text producer),("connector",text connector),("source",text source),
       ("externalReferences",encodeWith (listCodec textCodec) references)]
