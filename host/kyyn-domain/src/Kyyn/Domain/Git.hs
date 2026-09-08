module Kyyn.Domain.Git (Repository(..), GitRevision, gitRevision, revisionName) where

import Kyyn.Domain.Path (DirectoryScope)

newtype Repository = Repository DirectoryScope deriving (Eq, Show)
newtype GitRevision = GitRevision String deriving (Eq, Show)

gitRevision :: String -> Either String GitRevision
gitRevision value
  | length value `elem` [40,64] && all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') value = Right (GitRevision value)
  | otherwise = Left "Expected a full lowercase Git object ID"

revisionName :: GitRevision -> String
revisionName (GitRevision value) = value
