{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Domain.Root (Root(..), SourceRoot(..), RootDefinition(..), CheckedValue(..), factsLocation, isFactPath) where

import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Query (QueryDefinition)
import Kyyn.Domain.Value (CheckedValue(..))
import Data.List (isPrefixOf)
import Kyyn.Domain.Path (RelativePath, relativePath, relativeName)

-- Root-owned files outside this location are code, examples or auxiliary material.
factsLocation :: RelativePath
factsLocation = either error id (relativePath "facts")

isFactPath :: RelativePath -> Bool
isFactPath path = relativeName path == relativeName factsLocation
  || (relativeName factsLocation ++ "/") `isPrefixOf` relativeName path

data Root = Root { schema :: RootContract, facts :: FileTree, code :: FileTree } deriving (Eq, Show)
data SourceRoot = SourceRoot
  { schema :: RootContract, code :: FileTree, definition :: RootDefinition
  , loadedSources :: [RelativePath] } deriving (Eq, Show)
data RootDefinition = RootDefinition
  { schemaType :: String, schemaMetadata :: String, validator :: String
  , queries :: [QueryDefinition], sources :: FileTree }
  deriving (Eq, Show)
