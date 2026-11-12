{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Runtime.Evolution (knowledgeBaseCodec, rejectionValue) where
import Kyyn.Types.Evolution (EvolutionFailure(..))
import Kyyn.Types.KnowledgeBase (Recipe(..), FlowEntryRef(..))
import Kyyn.Recipe.Internal (KnowledgeBase(..), StoredRecipe(..))
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
    encodeStored (StoredRecipe method authored state) = record
      [("definition",encodeDefinition method authored),("state",state)]
    decodeStored value = do
      values <- fields ["definition","state"] value
      (method,authored) <- field "definition" definitionCodec values
      StoredRecipe method authored <$> field "state" (Codec id Right) values
    definitionCodec = Codec (uncurry encodeDefinition) decodeDefinition
    encodeDefinition (OpenAgent instructions) authored = tagged "OpenAgent" (Just
      (record [("instructions",encodeWith textCodec instructions),
        ("stateType",encodeWith textCodec (maybe "" id authored))]))
    encodeDefinition (ClosedAgent (FlowEntryRef entry)) _ = tagged "ClosedAgent" (Just
      (record [("flow",encodeWith textCodec entry)]))
    decodeDefinition value = do
      (name, payload) <- variant value
      case (name,payload) of
        ("OpenAgent", Just contents) -> do
          values <- fields ["instructions","stateType"] contents
          instructions <- field "instructions" textCodec values
          authored <- field "stateType" textCodec values
          pure (OpenAgent instructions,Just authored)
        ("ClosedAgent", Just contents) -> do
          values <- fields ["flow"] contents
          entry <- field "flow" textCodec values
          pure (ClosedAgent (FlowEntryRef entry),Nothing)
        _ -> Left "Expected OpenAgent or ClosedAgent recipe"
