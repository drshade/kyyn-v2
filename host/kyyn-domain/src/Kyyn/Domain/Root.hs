{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Domain.Root (Root(..), SourceRoot(..), RootDefinition(..), CheckedValue(..), factsLocation, isFactPath, curationLocation, isRootMaterial
  , pluginPackagesLocation, pluginSourceLocation, pluginOriginLocation, pluginManifestLocation, pluginPackageExclusions) where

import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Curation (Recipe, CurationRegister)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Query (QueryDefinition)
import Kyyn.Domain.Tool (ToolDefinition)
import Kyyn.Domain.Value (CheckedValue(..))
import Data.List (isPrefixOf)
import Kyyn.Domain.Path (RelativePath, relativePath, relativeName)

-- Root-owned files outside this location are code, examples or auxiliary material.
factsLocation :: RelativePath
factsLocation = either error id (relativePath "facts")

curationLocation :: RelativePath
curationLocation = either error id (relativePath "curation.dhall")

isRootMaterial :: RelativePath -> Bool
isRootMaterial path = isFactPath path || path == curationLocation

pluginPackagesLocation, pluginSourceLocation, pluginOriginLocation, pluginManifestLocation :: RelativePath
pluginPackagesLocation = either error id (relativePath "plugins/packages")
pluginSourceLocation = either error id (relativePath "source")
pluginOriginLocation = either error id (relativePath "origin.dhall")
pluginManifestLocation = either error id (relativePath "kyyn-plugin.dhall")

pluginPackageExclusions :: [RelativePath]
pluginPackageExclusions = map (either error id . relativePath) [".git", ".kyyn", "dist-newstyle", ".stack-work"]

isFactPath :: RelativePath -> Bool
isFactPath path = relativeName path == relativeName factsLocation
  || (relativeName factsLocation ++ "/") `isPrefixOf` relativeName path

data Root = Root { schema :: RootContract, facts :: FileTree, code :: FileTree, curation :: CurationRegister } deriving (Eq, Show)
data SourceRoot = SourceRoot
  { schema :: RootContract, code :: FileTree, definition :: RootDefinition
  , loadedSources :: [RelativePath] } deriving (Eq, Show)
data RootDefinition = RootDefinition
  { schemaType :: String, schemaMetadata :: String, validator :: String
  , queries :: [QueryDefinition], tools :: [ToolDefinition], recipes :: [Recipe], sources :: FileTree }
  deriving (Eq, Show)
