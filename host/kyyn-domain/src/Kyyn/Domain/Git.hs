module Kyyn.Domain.Git
  ( Repository(..), GitRevision, gitRevision, revisionName, GitUrl, gitUrl, gitUrlText, TreePath(..)
  , LocalBranch(..), GitTree(..), GitUser(..), CommitIdentity(..), CommitMetadata(..), RefUpdate(..)
  ) where

import Kyyn.Domain.Path (DirectoryScope, RelativePath)
import Kyyn.Domain.FileTree (FileTree)
import Data.List (isPrefixOf)
import Data.ByteString (ByteString)

newtype Repository = Repository DirectoryScope deriving (Eq, Show)
newtype GitRevision = GitRevision String deriving (Eq, Show)
newtype GitUrl = GitUrl String deriving (Eq, Show)

gitUrlText :: GitUrl -> String
gitUrlText (GitUrl value) = value

gitUrl :: String -> Either String GitUrl
gitUrl value
  | any (\prefix -> prefix `isPrefixOf` value && length value > length prefix) ["file://", "https://"]
  , not (any (`elem` value) ['\0', '\n', '\r']) = Right (GitUrl value)
  | otherwise = Left "Use a file:// or unauthenticated https:// Git URL, or a local checkout"

data TreePath = WholeTree | Subtree RelativePath deriving (Eq, Show)

-- Short branch name, checked by Git before use beneath refs/heads/.
newtype LocalBranch = LocalBranch String deriving (Eq, Show)
data GitTree = GitTree [(TreePath, FileTree)]
  | GitTreeWithFiles [(TreePath, FileTree)] [(RelativePath, ByteString)] deriving (Eq, Show)
data GitUser = GitUser String String deriving (Eq, Show)
data CommitIdentity = CommitIdentity
  { name :: String, email :: String, date :: String } deriving (Eq, Show)
data CommitMetadata = CommitMetadata
  { author :: CommitIdentity, committer :: CommitIdentity, message :: String }
  deriving (Eq, Show)
data RefUpdate = RefUpdated | RefNotUpdated (Maybe GitRevision) deriving (Eq, Show)

gitRevision :: String -> Either String GitRevision
gitRevision value
  | length value `elem` [40,64] && any (/= '0') value && all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') value = Right (GitRevision value)
  | otherwise = Left "Expected a nonzero full lowercase Git object ID"

revisionName :: GitRevision -> String
revisionName (GitRevision value) = value
