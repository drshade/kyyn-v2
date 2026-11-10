{-# LANGUAGE AllowAmbiguousTypes, GADTs, ScopedTypeVariables, TypeApplications, OverloadedStrings, OverloadedRecordDot #-}
-- | Target codecs compiled only after preparation selects the retained recipes.
module Kyyn.Runtime.TargetEvolution (RecipeBinding(..), definitionBinding, targetBinding, targetEvolutionEntry, targetProjectionEntry, module Kyyn.Evolution.Target, module Kyyn.Evolution.Preparation) where

import Data.Aeson (Value(..), object, (.=), (.:), withObject, toJSON)
import Data.Aeson.Types (parseEither, parseJSON)
import qualified Data.Aeson.KeyMap as Keys
import Data.List (sort)
import Agentic.Aeson (toAeson)
import Kyyn.Runtime.Entry (Entry, pureEntry)
import Kyyn.Types.Guest (GuestEntry(..), EvolutionContracts(..), describeContract)
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Runtime.Snapshot (snapshotWire, fromSnapshotWire)
import Kyyn.Runtime.Evolution (knowledgeBaseCodec, evolutionReplyValue)
import Kyyn.Runtime.Contract (fromWire)
import Control.Monad (unless)
import qualified Data.Text as Text
import Kyyn.Contract
import Kyyn.Types.KnowledgeBase (Recipe(..), FlowEntryRef(..))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..), CollectionDecl(..))
import Kyyn.Types.GuestBuild (RecipeReference(..))
import Kyyn.Types.StoredShape
import Kyyn.Recipe.Internal (RecipeType(..), RecipeDefinition(..))
import qualified Kyyn.Recipe.Internal as Typed
import Kyyn.Evolution.Stored
import Kyyn.Evolution.Target
import Kyyn.Evolution.Preparation
import Kyyn.Runtime.Contract (runtimeCodec)
import qualified Kyyn.Runtime.Json as Wire

-- The selected method/type reference identifies its generated codec. Open
-- instructions are data, so changing their text does not change state binding.
data RecipeBinding where
  RecipeBinding :: RecipeReference -> RecipeType state -> RecipeBinding

definitionBinding :: RecipeDefinition state -> RecipeBinding
definitionBinding (RecipeDefinition method binding@(RecipeType name _ _ _ _)) = RecipeBinding
  (case method of OpenAgent _ -> OpenState name; ClosedAgent (FlowEntryRef flow) -> ClosedFlow flow) binding

targetBinding :: forall root. Contract root
  => SchemaMetadata -> [RecipeBinding] -> Either ProjectionError (TargetBinding root)
targetBinding (SchemaMetadata _ _ collections) bindings = do
  compiled <- compileContract (contract @root)
  shape <- either (Left . ProjectionError []) Right (storedShape compiled.description)
  let codec = runtimeCodec compiled.codec
      decode (RecordedValue actual value) = do
        unless (canonicalShape actual == shape) (failure "Root shape differs from target")
        either (failure . Text.pack) Right (Wire.decodeWith codec value)
      encode value = Right (RecordedValue shape (Wire.encodeWith codec value))
  pure (TargetBinding [(name,field) | CollectionDecl name field _ <- collections] shape decode encode decodeRecipe encodeRecipe)
  where
    key (OpenAgent _) (Just name) = Right (OpenState name)
    key (ClosedAgent (FlowEntryRef name)) Nothing = Right (ClosedFlow name)
    key _ _ = failure "Invalid stored recipe definition"
    select reference = case [binding | binding@(RecipeBinding actual _) <- bindings, actual == reference] of
      [binding] -> Right binding
      _ -> failure "Recipe definition has no unique target state binding"
    decodeRecipe (StoredRecipe method authored (RecordedValue actual value)) = do
      reference <- key method authored
      RecipeBinding _ (RecipeType name identity shape encode decode) <- select reference
      unless (canonicalShape actual == canonicalShape shape) (failure "Recipe state shape differs from target")
      state <- either (failure . Text.pack) Right (decode value)
      pure (Typed.StoredRecipe method name identity (encode state))
    encodeRecipe (Typed.StoredRecipe method name identity value) = do
      let authored = case method of OpenAgent _ -> Just name; ClosedAgent _ -> Nothing
      reference <- key method authored
      RecipeBinding _ (RecipeType expected expectedIdentity shape encode decode) <- select reference
      unless (name == expected && identity == expectedIdentity) (failure "Recipe state identity differs from target")
      state <- either (failure . Text.pack) Right (decode value)
      pure (StoredRecipe method authored (RecordedValue shape (encode state)))

-- Snapshot and explanation are runtime arguments, never compiler inputs.
targetEvolutionEntry :: forall root. Contract root
  => (SchemaMetadata,[Text.Text]) -> [RecipeBinding] -> Evolution root -> Either ProjectionError Entry
targetEvolutionEntry = targetEntry "Evolution.evolution"

-- Generated without any reference to the authored evolution. A separate process
-- re-decodes the host's prepared boundary using the same target codec bindings.
targetProjectionEntry :: forall root. Contract root
  => (SchemaMetadata,[Text.Text]) -> [RecipeBinding] -> Either ProjectionError Entry
targetProjectionEntry metadata recipes = targetEntry @root "$evolution.project" metadata recipes identityEvolution

targetEntry :: forall root. Contract root
  => Text.Text -> (SchemaMetadata,[Text.Text]) -> [RecipeBinding] -> Evolution root -> Either ProjectionError Entry
targetEntry name (metadata,sources) recipes evolution = do
  compiled <- compileContract (contract @root)
  binding <- targetBinding @root metadata recipes
  let selected = TargetEvolutionContracts (describeContract compiled.description metadata sources)
      codec = knowledgeBaseCodec (runtimeCodec compiled.codec)
      run argument = do
        (snapshot,explanation) <- parseEither (withObject "Evolution input" $ \fields -> do
          unless (sort (Keys.keys fields) == ["explanation","snapshot"]) (fail "Invalid evolution input fields")
          (,) <$> (fields .: "snapshot" >>= parseJSON) <*> fields .: "explanation") argument
        input <- fromSnapshotWire snapshot
        case evaluateEvolution binding (Rationale explanation []) evolution input of
          Left rejection -> toAeson . fromWire <$> evolutionReplyValue codec (Left rejection)
          Right (result,observations) -> do
            steps <- traverse encodeObservation observations
            pure (object ["tag" .= String "Succeeded", "value" .= object
              ["after" .= toAeson (fromWire (Wire.encodeWith codec result)), "steps" .= steps]])
  pure (pureEntry (EvolutionEntry name selected) run)
  where
    encodeObservation (Observation origin (Rationale explanation evidence) before after) = do
      old <- snapshotWire before
      new <- snapshotWire after
      pure (object ["origin" .= String (case origin of Authored -> "authored"; TargetProjection -> "target-projection"),
        "rationale" .= object ["explanation" .= explanation, "evidence" .= map encodeEvidence evidence],
        "before" .= toJSON old, "after" .= toJSON new])
    encodeEvidence (EvidenceRef producer connector source references) = object
      ["producer" .= producer,"connector" .= connector,"source" .= source,"externalReferences" .= references]
