{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Runtime.Evolution (knowledgeBaseCodec, rejectionValue) where
import Kyyn.Types.Evolution (EvolutionFailure(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Recipe.Internal (KnowledgeBase(..), StoredRecipe(..), StoredDefinition(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.Diagnostic (ValidationReport(..))
import Data.Aeson (Value)
import Kyyn.Runtime.Json
import Kyyn.Runtime.Validation (encodeReportValue)

rejectionValue :: EvolutionFailure -> Either String Value
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
    encodeStored (StoredRecipe definition state) = record
      [("definition",encodeDefinition definition),("state",state)]
    decodeStored value = do
      values <- fields ["definition","state"] value
      definition <- field "definition" definitionCodec values
      StoredRecipe definition <$> field "state" (Codec id Right) values
    definitionCodec = Codec encodeDefinition decodeDefinition
    encodeDefinition (OpenDefinition instructions authored) = tagged "OpenAgent" (Just
      (record [("instructions",encodeWith textCodec instructions),
        ("stateType",encodeWith textCodec authored)]))
    encodeDefinition (ClosedDefinition (FlowEntryRef entry)) = tagged "ClosedAgent" (Just
      (record [("flow",encodeWith textCodec entry)]))
    decodeDefinition value = do
      (name, payload) <- variant value
      case (name,payload) of
        ("OpenAgent", Just contents) -> do
          values <- fields ["instructions","stateType"] contents
          instructions <- field "instructions" textCodec values
          authored <- field "stateType" textCodec values
          pure (OpenDefinition instructions authored)
        ("ClosedAgent", Just contents) -> do
          values <- fields ["flow"] contents
          entry <- field "flow" textCodec values
          pure (ClosedDefinition (FlowEntryRef entry))
        _ -> Left "Expected OpenAgent or ClosedAgent recipe"
