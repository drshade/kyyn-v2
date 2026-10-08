{-# LANGUAGE DuplicateRecordFields, NoFieldSelectors #-}
module GitHub.Types where

import Data.Text (Text)

-- | Capture repository activity, not source code.
data RepositoryConfig = RepositoryConfig
  { repositoryUrl :: Text
  , branch :: Maybe Text
  , since :: Maybe Text
  , tokenSecret :: Maybe Text
  } deriving (Eq, Show)

data Account = Account { login :: Text, url :: Text } deriving (Eq, Show)
data Comment = Comment
  { id :: Integer, author :: Maybe Account, body :: Text
  , createdAt :: Text, updatedAt :: Text, url :: Text
  } deriving (Eq, Show)
data Review = Review
  { id :: Integer, author :: Maybe Account, body :: Text, state :: Text
  , submittedAt :: Maybe Text, commitSha :: Text, url :: Text
  } deriving (Eq, Show)

data Issue = Issue
  { number :: Integer, title :: Text, body :: Text, state :: Text
  , stateReason :: Maybe Text, author :: Maybe Account, assignees :: [Account]
  , labels :: [Text], milestone :: Maybe Text
  , createdAt :: Text, updatedAt :: Text, closedAt :: Maybe Text
  , url :: Text, comments :: [Comment]
  } deriving (Eq, Show)

-- | Includes ordinary PR conversation and review summaries, not inline threads.
data PullRequest = PullRequest
  { discussion :: Issue, draft :: Bool, merged :: Bool, mergedAt :: Maybe Text
  , baseBranch :: Text, headBranch :: Text, baseSha :: Text, headSha :: Text
  , mergeCommitSha :: Maybe Text, reviews :: [Review]
  } deriving (Eq, Show)

-- | Git identities need not belong to a GitHub account.
data CommitIdentity = CommitIdentity
  { name :: Text, email :: Text, timestamp :: Text } deriving (Eq, Show)

-- | Paths and change kinds only; never patch text or file contents.
data FileChange = FileChange
  { path :: Text, status :: Text, previousPath :: Maybe Text } deriving (Eq, Show)
data Commit = Commit
  { sha :: Text, message :: Text
  , author :: Maybe CommitIdentity, committer :: Maybe CommitIdentity
  , parents :: [Text], url :: Text, files :: [FileChange], filesComplete :: Bool
  } deriving (Eq, Show)

data RepositoryItem = IssueItem Issue | PullRequestItem PullRequest | CommitItem Commit
  deriving (Eq, Show)
