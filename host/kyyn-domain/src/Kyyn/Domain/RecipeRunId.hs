module Kyyn.Domain.RecipeRunId (RecipeRunId, recipeRunId, runIdText) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)

newtype RecipeRunId = RecipeRunId String deriving (Eq, Ord, Show)
recipeRunId :: String -> Either String RecipeRunId
recipeRunId name
  | not (null name) && all (\c -> isAsciiLower c || isAsciiUpper c || isDigit c || c == '-') name = Right (RecipeRunId name)
  | otherwise = Left "Run ID must contain only ASCII letters, digits and hyphens"
runIdText :: RecipeRunId -> String
runIdText (RecipeRunId value) = value

