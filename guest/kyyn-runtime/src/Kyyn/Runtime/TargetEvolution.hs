{-# LANGUAGE AllowAmbiguousTypes, GADTs, ScopedTypeVariables, TypeApplications, OverloadedStrings, OverloadedRecordDot #-}
-- | Target codecs compiled only after preparation selects the retained recipes.
module Kyyn.Runtime.TargetEvolution (RecipeBinding(..), definitionBinding, targetBinding, targetEvolutionEntry, targetRecipeEvolutionEntry, targetProjectionEntry, module Kyyn.Evolution.Target, module Kyyn.Evolution.Preparation) where

import Data.Aeson (Value(..), object, (.=), (.:), withObject, toJSON)
import Data.Aeson.Types (parseEither, parseJSON)
import qualified Data.Aeson.KeyMap as Keys
import Data.List (sort)
import Kyyn.Runtime.Entry (Entry, pureEntry)
import Kyyn.Types.Guest (GuestEntry(..), EvolutionContracts(..), describeContract)
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Runtime.Snapshot (snapshotWire, fromSnapshotWire)
import Kyyn.Runtime.Evolution (knowledgeBaseCodec, rejectionValue)
import Kyyn.Recipe.Evolution (RecipeEvolution(..))
import Control.Monad.Trans.State.Strict (StateT(..), runStateT)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Control.Monad (unless)
import qualified Data.Text as Text
import Kyyn.Contract
import Kyyn.Types.KnowledgeBase (Recipe(..), RecipeId(..), FlowEntryRef(..))
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
targetEvolutionEntry metadata recipes evolution = targetEntry "Evolution.evolution" metadata recipes False (const (Right evolution))

-- Same-schema recipe steps are lifted into the same target edit/observation path.
targetRecipeEvolutionEntry :: forall root state. Contract root
  => (SchemaMetadata,[Text.Text]) -> [RecipeBinding] -> RecipeType state
  -> RecipeEvolution root state -> Either ProjectionError Entry
targetRecipeEvolutionEntry metadata recipes stateType (RecipeEvolution steps) =
  targetEntry @root "Evolution.evolution" metadata recipes True $ \argument -> do
    identity <- parseEither (withObject "Recipe evolution input" (.: "recipe")) argument
    pure (prepare (pure ()) (foldMap (\(reason,action) -> edit reason (selected identity action)) steps))
  where
    selected identity action = StateT $ \(Typed.KnowledgeBase root states) -> do
      original <- case [state | Fact (FactId name) state <- states, name == identity] of
        [state] -> Right state
        _ -> failure ("Recipe " <> identity <> " is missing or ambiguous")
      state <- Typed.readRecipeState (RecipeId identity) stateType original
      ((),(newRoot,newState)) <- runStateT action (root,state)
      let Typed.StoredRecipe method _ _ _ = original
          changed = Typed.storeRecipe (Typed.RecipeDefinition method stateType) newState
      pure ((),Typed.KnowledgeBase newRoot
        [Fact key (if name == identity then changed else value) | Fact key@(FactId name) value <- states])

-- Generated without any reference to the authored evolution. A separate process
-- re-decodes the host's prepared boundary using the same target codec bindings.
targetProjectionEntry :: forall root. Contract root
  => (SchemaMetadata,[Text.Text]) -> [RecipeBinding] -> Either ProjectionError Entry
targetProjectionEntry metadata recipes = targetEntry @root "$evolution.project" metadata recipes False (const (Right identityEvolution))

targetEntry :: forall root. Contract root
  => Text.Text -> (SchemaMetadata,[Text.Text]) -> [RecipeBinding] -> Bool -> (Value -> Either String (Evolution root)) -> Either ProjectionError Entry
targetEntry name (metadata,sources) recipes recipeBased choose = do
  compiled <- compileContract (contract @root)
  binding <- targetBinding @root metadata recipes
  let selected = TargetEvolutionContracts (describeContract compiled.description metadata sources)
      codec = knowledgeBaseCodec (runtimeCodec compiled.codec)
      run argument = do
        (snapshot,explanation) <- parseEither (withObject "Evolution input" $ \fields -> do
          unless (sort (Keys.keys fields) == (if recipeBased then ["explanation","recipe","snapshot"] else ["explanation","snapshot"])) (fail "Invalid evolution input fields")
          (,) <$> (fields .: "snapshot" >>= parseJSON) <*> fields .: "explanation") argument
        evolution <- choose argument
        input <- fromSnapshotWire snapshot
        case evaluateEvolution binding (Rationale explanation []) evolution input of
          Left rejection -> rejectionValue rejection
          Right (result,observations) -> do
            steps <- traverse encodeObservation observations
            pure (object ["tag" .= String "Succeeded", "value" .= object
              ["after" .= Wire.encodeWith codec result, "steps" .= steps]])
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
