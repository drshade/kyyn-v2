{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Runtime.Evolution (knowledgeBaseCodec, rejectionValue) where
import Kyyn.Types.Evolution (EvolutionFailure(..))
import Kyyn.Types.KnowledgeBase (Recipe(..), FlowEntryRef(..))
import Kyyn.Recipe.Internal (KnowledgeBase(..), StoredRecipe(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.Diagnostic (ValidationReport(..))
import Text.JSON.Types (JSValue)
import Kyyn.Runtime.Json
import Kyyn.Runtime.Validation (encodeReportValue)

rejectionValue :: EvolutionFailure -> Either String JSValue
rejectionValue (EvolutionFailure diagnostics) = tagged "Rejected" . Just <$> encodeReportValue (ValidationReport diagnostics)

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

