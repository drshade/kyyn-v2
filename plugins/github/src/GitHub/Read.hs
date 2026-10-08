{-# LANGUAGE OverloadedStrings #-}
module GitHub.Read (item, issue, pullRequest, commit) where

import Data.Text (Text)
import GitHub.Types
import Kyyn.Plugin

item :: Text -> EvidenceSnapshot RepositoryItem -> CapturedRead RepositoryItem (Either FetchError RepositoryItem)
item key snapshot = do
  found <- readEvidence snapshot (EvidenceId key)
  pure $ case found of
    Left problem -> Left problem
    Right Nothing -> Left (FetchError "No captured GitHub item with this evidence ID")
    Right (Just (Evidence _ _ Truncated)) -> Left (FetchError "GitHub payload is truncated; clear and refetch to restore commit payloads")
    Right (Just (Evidence _ _ (Available value))) -> Right value

issue :: Text -> EvidenceSnapshot RepositoryItem -> CapturedRead RepositoryItem (Either FetchError Issue)
issue key snapshot = fmap (>>= select) (item key snapshot)
  where select (IssueItem value) = Right value
        select _ = Left (FetchError "Evidence is not an issue")
pullRequest :: Text -> EvidenceSnapshot RepositoryItem -> CapturedRead RepositoryItem (Either FetchError PullRequest)
pullRequest key snapshot = fmap (>>= select) (item key snapshot)
  where select (PullRequestItem value) = Right value
        select _ = Left (FetchError "Evidence is not a pull request")
commit :: Text -> EvidenceSnapshot RepositoryItem -> CapturedRead RepositoryItem (Either FetchError Commit)
commit key snapshot = fmap (>>= select) (item key snapshot)
  where select (CommitItem value) = Right value
        select _ = Left (FetchError "Evidence is not a commit")
