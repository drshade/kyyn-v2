module Kyyn.Plumbing.Protocol.Recipes
  ( recipeShape, recipesShape, recipeValue, parseRecipe, recipesValue, parseRecipes
  , knowledgeBaseValue, parseKnowledgeBase ) where

import Control.Monad (unless)
import Data.Aeson (Value, object, (.=), (.:), withObject, toJSON)
import Data.Aeson.Types (Parser, parseJSON)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import Data.List (sort)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (KnowledgeBase(..), Recipe(..))

recipeShape :: Shape
recipeShape = Record [("instructions", Scalar TextScalar)]

recipesShape :: Shape
recipesShape = List (Record [("id", Scalar TextScalar), ("value", recipeShape)])

recipeValue :: Recipe -> Value
recipeValue (Recipe instructions) = object ["instructions" .= instructions]

parseRecipe :: Value -> Parser Recipe
parseRecipe = exact "Recipe" ["instructions"] $ \fields -> Recipe <$> fields .: "instructions"

recipesValue :: [Fact Recipe] -> Value
recipesValue entries = toJSON [object ["id" .= name, "value" .= recipeValue payload] |
  Fact (FactId name) payload <- entries]

parseRecipes :: Value -> Parser [Fact Recipe]
parseRecipes value = parseJSON value >>= traverse
  (exact "Recipe fact" ["id","value"] $ \fields ->
    Fact <$> (FactId <$> fields .: "id") <*> (fields .: "value" >>= parseRecipe))

knowledgeBaseValue :: KnowledgeBase Value -> Value
knowledgeBaseValue (KnowledgeBase value entries) = object
  ["facts" .= value, "recipes" .= recipesValue entries]

parseKnowledgeBase :: Value -> Parser (KnowledgeBase Value)
parseKnowledgeBase = exact "KnowledgeBase" ["facts","recipes"] $ \fields ->
  KnowledgeBase <$> fields .: "facts" <*> (fields .: "recipes" >>= parseRecipes)

exact :: String -> [Key] -> (Keys.KeyMap Value -> Parser a) -> Value -> Parser a
exact label expected decode = withObject label $ \fields -> do
  unless (sort expected == sort (Keys.keys fields)) (fail (label ++ ": unexpected or missing fields"))
  decode fields
