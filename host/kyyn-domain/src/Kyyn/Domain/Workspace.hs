module Kyyn.Domain.Workspace
  ( EvolutionState(..), WorkspaceManifest(..), WorkspaceSnapshot(..)
  , projectWorkspace, matchesCapturedInputs
  ) where

import Data.List (isPrefixOf, stripPrefix)
import Kyyn.Domain.FileTree (FileTree, files, fileTree)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.Path (relativeName, relativePath)

data EvolutionState = Draft | Ready | Accepted deriving (Eq, Show)

data WorkspaceManifest = WorkspaceManifest
  { beforeRevision :: GitRevision
  , name :: String
  , explanation :: String
  , state :: EvolutionState
  } deriving (Eq, Show)

data WorkspaceSnapshot = WorkspaceSnapshot
  { manifest :: WorkspaceManifest
  , beforeSource :: FileTree
  , targetCode :: FileTree
  , changeSource :: FileTree
  , notes :: FileTree
  } deriving (Eq, Show)

projectWorkspace :: WorkspaceManifest -> FileTree -> Either String WorkspaceSnapshot
projectWorkspace manifest tree
  | any (not . allowed . relativeName . fst) (files tree) = Left "Unexpected file outside workspace layout"
  | any (\(p,_) -> relativeName p == "target/facts" || "target/facts/" `isPrefixOf` relativeName p) (files tree) =
      Left "Target facts must be produced by the evolution"
  | otherwise = WorkspaceSnapshot manifest <$> subtree "before/" <*> subtree "target/" <*>
      subtree "change/" <*> subtree "notes/"
  where
    allowed p = p `elem` ["manifest.dhall", "result.dhall"] || any (`isPrefixOf` p) ["before/", "target/", "change/", "notes/"]
    subtree prefix = traverse (\(p,b) -> (,b) <$> relativePath p)
      [(p,b) | (path,b) <- files tree, Just p <- [stripPrefix prefix (relativeName path)]] >>= fileTree

matchesCapturedInputs :: WorkspaceSnapshot -> WorkspaceSnapshot -> Bool
matchesCapturedInputs left right = inputs left == inputs right
  where
    inputs (WorkspaceSnapshot (WorkspaceManifest revision name explanation _) before target change _) =
      (revision, name, explanation, before, target, change)
