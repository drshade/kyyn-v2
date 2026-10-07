module Kyyn.Plumbing.Protocol.Recipes
  ( methodShape, methodValue, parseMethod
  , recipeDefinitionShape, recipeDefinitionValue, parseRecipeDefinition
  , recipesShape, recipesValue, parseRecipes
  , proposedRecipeValue, parseProposedRecipe, knowledgeBaseValue, parseKnowledgeBase ) where

import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=), (.:), withObject, toJSON)
import Data.Aeson.Types (Parser, parseJSON)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import Data.List (sort)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Contract (contractFingerprint, parseContractFingerprint)
import Kyyn.Domain.Recipe (KnowledgeBase(..), RecipeDefinition(..), ProposedRecipe(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (Recipe(..), FlowEntryRef(..))

methodShape :: Shape
methodShape = Union
  [("OpenAgent", Just (Record [("instructions",Scalar TextScalar)])),
   ("ClosedAgent", Just (Record [("flow", Scalar TextScalar)]))]

recipeDefinitionShape :: Shape
recipeDefinitionShape = Union
  [("OpenAgent",Just (Record [("instructions",Scalar TextScalar),("stateType",Scalar TextScalar)])),
   ("ClosedAgent",Just (Record [("flow",Scalar TextScalar)]))]

recipesShape :: Shape
recipesShape = List (Record [("id", Scalar TextScalar), ("value", recipeDefinitionShape)])

methodValue :: Recipe -> Value
methodValue (OpenAgent instructions) = object
  ["tag" .= ("OpenAgent" :: String), "value" .= object ["instructions" .= instructions]]
methodValue (ClosedAgent (FlowEntryRef entry)) = object
  ["tag" .= ("ClosedAgent" :: String), "value" .= object ["flow" .= entry]]

parseMethod :: Value -> Parser Recipe
parseMethod = exact "Recipe method" ["tag","value"] (\values -> do
      tag <- values .: "tag" :: Parser String
      payload <- values .: "value"
      case tag of
        "OpenAgent" -> exact "OpenAgent" ["instructions"] (\p -> OpenAgent <$> p .: "instructions") payload
        "ClosedAgent" -> exact "ClosedAgent" ["flow"] (\p -> ClosedAgent . FlowEntryRef <$> p .: "flow") payload
        _ -> fail "Unknown recipe constructor")

recipeDefinitionValue :: RecipeDefinition -> Value
recipeDefinitionValue (OpenRecipe instructions stateType) = object
  ["tag" .= ("OpenAgent" :: String), "value" .= object ["instructions" .= instructions,"stateType" .= stateType]]
recipeDefinitionValue (ClosedRecipe (FlowEntryRef entry)) = object
  ["tag" .= ("ClosedAgent" :: String), "value" .= object ["flow" .= entry]]

parseRecipeDefinition :: Value -> Parser RecipeDefinition
parseRecipeDefinition = exact "Recipe definition" ["tag","value"] $ \values -> do
  tag <- values .: "tag" :: Parser String
  payload <- values .: "value"
  case tag of
    "OpenAgent" -> exact "OpenAgent" ["instructions","stateType"]
      (\p -> OpenRecipe <$> p .: "instructions" <*> p .: "stateType") payload
    "ClosedAgent" -> exact "ClosedAgent" ["flow"] (\p -> ClosedRecipe . FlowEntryRef <$> p .: "flow") payload
    _ -> fail "Unknown recipe constructor"

recipesValue :: [Fact RecipeDefinition] -> Value
recipesValue entries = toJSON [object ["id" .= name, "value" .= recipeDefinitionValue payload] |
  Fact (FactId name) payload <- entries]

parseRecipes :: Value -> Parser [Fact RecipeDefinition]
parseRecipes value = parseJSON value >>= traverse
  (exact "Recipe fact" ["id","value"] $ \fields ->
    Fact <$> (FactId <$> fields .: "id") <*> (fields .: "value" >>= parseRecipeDefinition))

proposedRecipeValue :: ProposedRecipe -> Value
proposedRecipeValue (ProposedRecipe method stateType identity value) = object
  ["method" .= methodValue method,"stateType" .= stateType,
   "stateContract" .= contractFingerprint identity,"state" .= value]

parseProposedRecipe :: Value -> Parser ProposedRecipe
parseProposedRecipe = exact "Recipe" ["method","stateType","stateContract","state"] $ \fields ->
  ProposedRecipe <$> (fields .: "method" >>= parseMethod) <*> fields .: "stateType"
    <*> (fields .: "stateContract" >>= either fail pure . parseContractFingerprint) <*> fields .: "state"

knowledgeBaseValue :: KnowledgeBase Value ProposedRecipe -> Value
knowledgeBaseValue (KnowledgeBase value entries) = object
  ["facts" .= value, "recipes" .= [object ["id" .= name,"value" .= proposedRecipeValue recipe] |
    Fact (FactId name) recipe <- entries]]

parseKnowledgeBase :: Value -> Parser (KnowledgeBase Value ProposedRecipe)
parseKnowledgeBase = exact "KnowledgeBase" ["facts","recipes"] $ \fields ->
  KnowledgeBase <$> fields .: "facts" <*> (fields .: "recipes" >>= parseJSON >>= traverse
    (exact "Recipe fact" ["id","value"] $ \entry ->
      Fact <$> (FactId <$> entry .: "id") <*> (entry .: "value" >>= parseProposedRecipe)))

exact :: String -> [Key] -> (Keys.KeyMap Value -> Parser a) -> Value -> Parser a
exact label expected decode = withObject label $ \fields -> do
  unless (sort expected == sort (Keys.keys fields)) (fail (label ++ ": unexpected or missing fields"))
  decode fields
