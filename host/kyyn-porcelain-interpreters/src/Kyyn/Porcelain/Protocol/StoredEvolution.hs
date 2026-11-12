{-# LANGUAGE OverloadedRecordDot #-}
-- | Execute a captured target guest against immutable stored data. No old code
-- or historical contract participates in evaluation or projection verification.
module Kyyn.Porcelain.Protocol.StoredEvolution (executeStoredEvolution) where

import Kyyn.Types.Wire (decodeWire)
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (Value, Object, object, (.=), (.:), withObject, withArray)
import Data.Aeson.Types (Parser, parseEither, parseJSON)
import qualified Data.Aeson.KeyMap as Keys
import Data.Aeson.Key (Key)
import Data.Foldable (toList)
import Data.List (sort)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Contract (contractId, rootSchema, checkRootLayout, rootType)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.CompiledEntry (compiledEntries, entryDescription)
import Kyyn.Domain.Guest (CheckedGuest, checkedEntries, InspectedSchema(..))
import Kyyn.Domain.Recipe (KnowledgeBase(..), ProposedRecipe(..), StoredRecipe(..), RecipeDefinition(..), recipeMethod)
import Kyyn.Domain.StoredSnapshot (StoredSnapshot)
import Kyyn.Domain.SnapshotReport
import Kyyn.Domain.Root (Root(..))
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Types.Evolution (EvolutionFailure(..), Rationale(..))
import Kyyn.Types.Diagnostic (ValidationReport(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Fact (Fact(..))
import Kyyn.Types.KnowledgeBase (RecipeId(..), FlowEntryRef(..))
import Kyyn.Domain.DataType (haskellType)
import qualified Kyyn.Types.Guest as G
import Kyyn.Types.SnapshotWire (SnapshotWire)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeEntry)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Protocol.Recipes (parseKnowledgeBase)
import Kyyn.Plumbing.Protocol.Validation (parseReport)
import Kyyn.Porcelain.Capability.RootStore (RootStore, checkRootValue, checkRecipeValue, materializeRoot, encodeRootRecipes)
import Kyyn.Porcelain.Protocol.StoredSnapshot (readStoredSnapshot)
import Kyyn.Porcelain.Protocol.SnapshotWire (encodeSnapshotWire, decodeSnapshotWire)

executeStoredEvolution :: (GuestExecution :> es, DhallHandling :> es, RootStore :> es, Failure :> es)
  => CompiledProgram -> CheckedGuest -> FileTree -> Rationale -> Maybe RecipeId -> StoredSnapshot
  -> Eff es (Either [Diagnostic] (Root,[SnapshotStep]))
executeStoredEvolution program guest targetCode reason selectedRecipe input = runExceptT $ do
  target <- case [schema.contract | G.EvolutionEntry "Evolution.evolution" (G.TargetEvolutionContracts schema) <- checkedEntries guest] of
    [contract] -> checked (checkRootLayout contract)
    _ -> bad "Expected one target-only evolution entry"
  unless ([contractId schema.contract | G.EvolutionEntry "$evolution.project" (G.TargetEvolutionContracts schema) <- checkedEntries guest]
    == [contractId (rootSchema target)]) (bad "Projection entry does not describe the same target contract")
  (returned,observations) <- invoke "Evolution.evolution" input
  prepared <- case [before | SnapshotObservation TargetProjection _ before _ <- observations] of
    [before] -> pure before
    _ -> bad "Expected exactly one target projection"
  -- A new process, no authored preparation/edit action, same target codecs.
  (projectedValue,projectionSteps) <- invoke "$evolution.project" prepared
  projected <- case projectionSteps of
    [SnapshotObservation TargetProjection explanation before after]
      | explanation == reason && equivalentSnapshots before prepared -> pure after
    _ -> bad "Independent projection did not return its exact input and one system step"
  projectedRoot <- materialize target projectedValue
  canonicalProjection <- snapshotOf projectedRoot
  unless (equivalentSnapshots projected canonicalProjection) (bad "Independent projection differs from its encoded target result")
  result <- materialize target returned
  final <- snapshotOf result
  report <- checked (checkSnapshotContinuity reason input canonicalProjection final observations)
  pure (result,report)
  where
    invoke name snapshot = do
      entry <- case [selected | selected <- compiledEntries program guest,
        G.EvolutionEntry actual (G.TargetEvolutionContracts _) <- [entryDescription selected], actual == name] of
        [selected] -> pure selected
        _ -> bad "Missing or duplicate target evolution entry"
      wire <- either bad pure (encodeSnapshotWire snapshot)
      let Rationale explanation _ = reason
      bytes <- ExceptT (Right <$> executeEntry entry (object (["snapshot" .= wire,"explanation" .= explanation] ++
        ["recipe" .= identity | name == "Evolution.evolution", Just (RecipeId identity) <- [selectedRecipe]])))
      decoded <- either bad pure (decodeWire bytes >>= parseEither reply)
      case decoded of
        Left (EvolutionFailure diagnostics) -> throwE diagnostics
        Right (value,steps) -> do
          observations <- traverse (\(origin,rationale,before,after) ->
            SnapshotObservation origin rationale <$> ExceptT (decodeSnapshotWire before) <*> ExceptT (decodeSnapshotWire after)) steps
          pure (value,observations)
    materialize target (KnowledgeBase value recipes) = do
      root <- ExceptT (checkRootValue target value)
      states <- traverse checkState recipes
      ExceptT (materializeRoot target targetCode (KnowledgeBase root states))
    checkState (Fact identity (ProposedRecipe definition value)) = do
      let method = recipeMethod definition
      contract <- stateContract definition
      let name = case definition of
            OpenRecipe _ authored -> authored
            ClosedRecipe _ -> haskellType (rootType contract)
      state <- ExceptT (checkRecipeValue contract value)
      pure (Fact identity (StoredRecipe method name contract state))
    stateContract definition = case [schema.contract | G.ContractEntry selected schema <- checkedEntries guest,
        selected == reference definition] of
      [contract] -> pure contract
      _ -> bad "Returned recipe has no unique compiler-described target state"
    reference (OpenRecipe _ "()") = "$import.unit"
    reference (OpenRecipe _ name) = "$import.state.Target." <> Text.pack name
    reference (ClosedRecipe (FlowEntryRef flow)) = "$import.flow." <> flow
    snapshotOf (Root _ facts _ recipes) = do
      definitions <- ExceptT (encodeRootRecipes recipes)
      tree <- either bad pure (fileTree (files facts ++ files definitions))
      ExceptT (readStoredSnapshot tree)
    checked = either throwE pure
    bad = throwE . pure . errorDiagnostic "evolution.stored"

type WireObservation = (StepOrigin,Rationale,SnapshotWire,SnapshotWire)
reply :: Value -> Parser (Either EvolutionFailure (KnowledgeBase Value ProposedRecipe,[WireObservation]))
reply = exact "Evolution reply" ["tag","value"] $ \fields -> do
  tag <- fields .: "tag" :: Parser Text.Text
  value <- fields .: "value"
  case tag of
    "Rejected" -> do
      ValidationReport diagnostics <- parseReport value
      pure (Left (EvolutionFailure diagnostics))
    "Succeeded" -> Right <$> exact "Evolution output" ["after","steps"] (\output ->
      (,) <$> (output .: "after" >>= parseKnowledgeBase) <*> (output .: "steps" >>= list observation)) value
    _ -> fail "Unknown evolution outcome"
  where
    observation = exact "Observation" ["origin","rationale","before","after"] $ \fields -> do
      label <- fields .: "origin" :: Parser Text.Text
      origin <- case label of "authored" -> pure Authored; "target-projection" -> pure TargetProjection; _ -> fail "Unknown observation origin"
      (origin,,,) <$> (fields .: "rationale" >>= rationale) <*>
        (fields .: "before" >>= parseJSON) <*> (fields .: "after" >>= parseJSON)
    rationale = exact "Rationale" ["explanation","evidence"] $ \fields ->
      Rationale <$> fields .: "explanation" <*> (fields .: "evidence" >>= list evidence)
    evidence = exact "Evidence" ["producer","connector","source","externalReferences"] $ \fields ->
      EvidenceRef <$> fields .: "producer" <*> fields .: "connector" <*> fields .: "source" <*> fields .: "externalReferences"
    list parser = withArray "List" (traverse parser . toList)

exact :: String -> [Key] -> (Object -> Parser a) -> Value -> Parser a
exact label expected parse = withObject label $ \fields -> do
  unless (sort (Keys.keys fields) == sort expected) (fail (label ++ ": unexpected/missing fields"))
  parse fields
