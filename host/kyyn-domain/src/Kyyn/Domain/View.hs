module Kyyn.Domain.View (ViewDefinition(..), viewPath, isViewPath) where

import Data.List (isPrefixOf)
import Kyyn.Domain.Path (RelativePath, relativePath, relativeName)

data ViewDefinition = ViewDefinition
  { name :: String, description :: String, page :: RelativePath } deriving (Eq, Show)

isViewPath :: RelativePath -> Bool
isViewPath path = "views/" `isPrefixOf` relativeName path

viewPath :: String -> Either String RelativePath
viewPath value = do
  path <- relativePath value
  case split value of
    "views":directory:rest | not (null directory), not (null rest) -> Right path
    _ -> Left "View pages must live in a dedicated views/<directory>/ subdirectory"
  where
    split s = case break (== '/') s of (a,[]) -> [a]; (a,_:b) -> a : split b
