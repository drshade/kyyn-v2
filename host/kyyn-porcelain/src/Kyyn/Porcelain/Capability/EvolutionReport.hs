{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Porcelain.Capability.EvolutionReport (checkEvolutionReport) where

import qualified Data.Text as Text
import Control.Monad (unless)
import Data.Aeson (Value, withObject, withArray, (.:))
import Data.Aeson.Types (parseEither)
import Data.Aeson.Key (fromString)
import Data.Foldable (toList)
import Data.List (nub, sort)
import Effectful (Eff, (:>))
import Kyyn.Domain.Contract
import Kyyn.Domain.Recipe
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.EvolutionReport
import Kyyn.Domain.Root (CheckedValue)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Porcelain.Capability.RootStore (RootStore, checkRootValue, checkRecipeValue)

checkEvolutionReport :: RootStore :> es
  => [(String, CheckedContract)] -> RootContract -> KnowledgeBase Value ProposedRecipe -> RootContract -> EvolutionObservation
  -> Eff es (Either [Diagnostic] (KnowledgeBase CheckedValue StoredRecipe, EvolutionReport))
checkEvolutionReport stateContracts source input target (EvolutionObservation output steps) =
  case resolveBoundaries of
    Left diagnostics -> pure (Left diagnostics)
    Right boundaries -> do
      checked <- traverse (\(contract,KnowledgeBase value recipes) -> do
        result <- checkRootValue contract value
        checkedRecipes <- checkRecipes recipes
        pure (KnowledgeBase <$> result <*> checkedRecipes)) boundaries
      pure $ do
        values <- sequence checked
        factSets <- traverse (\((contract,KnowledgeBase value _),KnowledgeBase _ recipes) ->
          (,recipes) <$> identifiedFacts contract value) (zip boundaries values)
        let first = ObservedRoot (identity source) input
            lastRoot = ObservedRoot (identity target) output
            starts = [before | StepObservation _ before _ <- steps] ++ [lastRoot]
            ends = first : [after | StepObservation _ _ after <- steps]
        mapM_ (\(index, expected, actual) -> unless (expected == actual)
          (reject ("Boundary " ++ show index ++ " does not continue the preceding step: expected contract " ++
            observedIdentity expected ++ ", received " ++ observedIdentity actual ++
            "; both the contract and root value must match")))
          (zip3 [1 :: Int ..] ends starts)
        unless (identity source == identity target ||
          all (\(StepObservation _ (ObservedRoot b _) (ObservedRoot a _)) ->
            not (b == identity target && a == identity source)) steps)
          (reject "An evolution cannot return to Before after entering After")
        reports <- stepReports steps (drop 1 factSets)
        case reverse values of
          final : _ -> Right (final, EvolutionReport [] reports)
          [] -> reject "Missing evolution boundaries"
  where
    checkRecipes recipes = do
      checked <- traverse checkRecipe recipes
      pure $ do
        values <- sequence checked
        _ <- checkRecipeDefinitions [Fact ident (recipeDefinition recipe) | Fact ident recipe <- values]
        pure values
    checkRecipe (Fact ident (ProposedRecipe method name fingerprint value)) =
      case nub [contract | (selected,contract) <- stateContracts,
                 selected == name, contractId contract == fingerprint] of
        [contract] -> fmap (fmap (Fact ident . StoredRecipe method name contract)) (checkRecipeValue contract value)
        _ -> pure (reject ("Recipe state names an unknown contract: " ++ name))
    contracts = nub [source, target]
    observedIdentity (ObservedRoot name _) = name
    resolve (ObservedRoot selected value) = case filter ((== selected) . identity) contracts of
      [contract] -> Right (contract, value)
      _ -> reject ("Observation names an unknown or ambiguous contract: " ++ selected)
    resolveBoundaries = do
      observed <- traverse resolve [root | StepObservation _ before after <- steps, root <- [before,after]]
      pure ((source,input) : observed ++ [(target,output)])
    stepReports [] [_] = Right []
    stepReports (StepObservation rationale _ _ : rest) (before : after : remaining) =
      (StepReport rationale (diff (fst before) (fst after) ++ recipeDiff (snd before) (snd after)) :) <$> stepReports rest remaining
    stepReports _ _ = reject "Missing step boundaries"

identity :: RootContract -> String
identity = contractFingerprint . contractId . rootSchema

type IdentifiedFacts = [((String, String), RecordedFact)]

identifiedFacts :: RootContract -> Value -> Either [Diagnostic] IdentifiedFacts
identifiedFacts contract value = either (reject . ("Invalid fact membership: " ++)) Right $ do
  collections <- traverse readCollection (collectionContracts (rootSchema contract))
  pure (concat collections)
  where
    readCollection (CollectionContract name field _ _) = do
      facts <- parseEither (withObject "Root" (\o -> o .: fromString field >>= withArray "Collection" (pure . toList))) value
      identified <- traverse (\fact -> do
        identifier <- parseEither (withObject "Fact" (.: "id")) fact
        pure ((name,identifier), RecordedFact contract fact)) facts
      let keys = map fst identified
      unless (length keys == length (nub keys)) (Left ("Duplicate fact ID in collection " ++ name))
      pure identified

diff :: IdentifiedFacts -> IdentifiedFacts -> [Change]
diff before after =
  [FactChange collection (FactId (Text.pack identifier)) old new |
    key@(collection,identifier) <- sort (nub (map fst before ++ map fst after)),
    let old = lookup key before, let new = lookup key after, old /= new]

recipeDiff :: [Fact StoredRecipe] -> [Fact StoredRecipe] -> [Change]
recipeDiff before after =
  [RecipeChange (FactId name) old new |
    name <- sort (nub (map fst earlier ++ map fst later)),
    let old = lookup name earlier, let new = lookup name later, old /= new]
  where
    earlier = [(name,payload) | Fact (FactId name) payload <- before]
    later = [(name,payload) | Fact (FactId name) payload <- after]

reject :: String -> Either [Diagnostic] a
reject = Left . pure . errorDiagnostic "evolution.observation"
