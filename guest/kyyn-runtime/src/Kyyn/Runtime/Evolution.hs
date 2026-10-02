{-# LANGUAGE GADTs, EmptyDataDecls, EmptyCase #-}
module Kyyn.Runtime.Evolution (NoRequests, executeEvolution, encodeEvolutionReply, knowledgeBaseCodec) where

import Kyyn.Evolution.Internal (EvolutionOutput(..), StepObservation(..), RecordedRoot(..))
import Kyyn.Types.Evolution (EvolutionFailure(..), Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Evidence (EvidenceId(..))
import Kyyn.Types.Curation
import Kyyn.Types.KnowledgeBase (KnowledgeBase(..), Recipe(..), FlowEntryRef(..))
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
      [("id",encodeWith stringCodec name),
       ("value",encodePayload payload)]
    decodeRecipe value = do
      values <- fields ["id","value"] value
      name <- field "id" stringCodec values
      payload <- field "value" payloadCodec values
      pure (Fact (FactId name) payload)
    payloadCodec = Codec encodePayload decodePayload
    encodePayload (OpenAgent instructions) = tagged "OpenAgent" (Just
      (record [("instructions",encodeWith stringCodec instructions)]))
    encodePayload (ClosedAgent (FlowEntryRef entry)) = tagged "ClosedAgent" (Just
      (record [("flow",encodeWith stringCodec entry)]))
    decodePayload value = do
      (name, payload) <- variant value
      case (name,payload) of
        ("OpenAgent", Just contents) -> do
          values <- fields ["instructions"] contents
          OpenAgent <$> field "instructions" stringCodec values
        ("ClosedAgent", Just contents) -> do
          values <- fields ["flow"] contents
          ClosedAgent . FlowEntryRef <$> field "flow" stringCodec values
        _ -> Left "Expected OpenAgent or ClosedAgent recipe"

executeEvolution :: Codec a -> Codec b
  -> (a -> Program NoRequests (Either EvolutionFailure (EvolutionOutput b)))
  -> String -> Either String String
executeEvolution beforeCodec afterCodec selected input = do
  before <- parseValue input >>= decodeWith beforeCodec
  case selected before of
    Pure result -> encodeEvolutionReply afterCodec result
    Request operation _ -> case operation of {}

encodeEvolutionReply :: Codec a -> Either EvolutionFailure (EvolutionOutput a) -> Either String String
encodeEvolutionReply codec result = do
  value <- case result of
    Left (EvolutionFailure diagnostics) -> do
      report <- encodeReportValue (ValidationReport diagnostics)
      pure (tagged "Rejected" (Just report))
    Right (EvolutionOutput output steps curation) -> pure (tagged "Succeeded" (Just (record
      [("after", encodeWith codec output), ("steps", JSArray (map encodeStep steps)),
       ("curation",encodeCuration curation)])))
  printValue value
  where
    text = encodeWith stringCodec
    encodeCuration Nothing = tagged "None" Nothing
    encodeCuration (Just (Curation (RecipeId recipe) handled)) = tagged "Some" (Just
      (record [("recipe",text recipe),("handled",JSArray (map acknowledgement handled))]))
    scope (EvidenceScope plugin instanceName fetch) = record
      [("plugin",text plugin),("instance",text instanceName),("fetch",text fetch)]
    acknowledgement (EntireBatch selected) = tagged "EntireBatch" (Just (scope selected))
    acknowledgement (IndividualRecords selected ids) = tagged "IndividualRecords" (Just
      (record [("scope",scope selected),("ids",JSArray [text item | EvidenceId item <- ids])]))
    encodeRoot (RecordedRoot contract value) = record [("contract",text contract),("value",value)]
    encodeStep (StepObservation rationale before after) = record
      [("rationale",encodeRationale rationale),("before",encodeRoot before),("after",encodeRoot after)]
    encodeRationale (Rationale explanation evidence) = record
      [("explanation",text explanation),("evidence",JSArray (map encodeEvidence evidence))]
    encodeEvidence (EvidenceRef producer connector source references) = record
      [("producer",text producer),("connector",text connector),("source",text source),
       ("references",encodeWith (listCodec stringCodec) references)]
