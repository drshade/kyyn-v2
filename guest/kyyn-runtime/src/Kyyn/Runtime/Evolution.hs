{-# LANGUAGE GADTs, EmptyDataDecls, EmptyCase #-}
module Kyyn.Runtime.Evolution (NoRequests, executeEvolution, encodeEvolutionReply) where

import Kyyn.Evolution.Internal (EvolutionOutput(..), StepObservation(..), RecordedRoot(..))
import Kyyn.Types.Evolution (EvolutionFailure(..), Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Evidence (EvidenceId(..))
import Kyyn.Types.Curation
import Kyyn.Types.Diagnostic (ValidationReport(..))
import Kyyn.Types.Program (Program(..))
import Kyyn.Runtime.Json
import Kyyn.Runtime.Validation (encodeReportValue)
import Text.JSON.Types (JSValue(JSArray))

data NoRequests a

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
