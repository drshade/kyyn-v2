module Kyyn.Domain.KnowledgeBase (KnowledgeBase(..), knowledgeBasePath) where

import Kyyn.Domain.Git (Repository, TreePath(..))
import Kyyn.Domain.Path (RelativePath, relativeName, relativePath)

data KnowledgeBase = KnowledgeBase
  { repository :: Repository
  , prefix :: TreePath
  } deriving (Eq, Show)

knowledgeBasePath :: KnowledgeBase -> RelativePath -> Either String RelativePath
knowledgeBasePath (KnowledgeBase _ WholeTree) path = Right path
knowledgeBasePath (KnowledgeBase _ (Subtree prefix)) path =
  relativePath (relativeName prefix ++ "/" ++ relativeName path)
