{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Domain.Evolution
  ( EvolutionId, evolutionId, evolutionIdName, EvolutionName(..), EvolutionWorkspace(..), Before(..)
  , EvolutionContext(..), CapturedEvolution(..)
  ) where

import Data.Coerce (coerce)
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Workspace (WorkspaceSnapshot)

newtype EvolutionId = EvolutionId String deriving (Eq, Show)
newtype EvolutionName = EvolutionName String deriving (Eq, Show)

evolutionId :: String -> Either String EvolutionId
evolutionId value
  | not (null value) && all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') value = Right (EvolutionId value)
  | otherwise = Left "Evolution ID must be nonempty lowercase hexadecimal"

evolutionIdName :: EvolutionId -> String
evolutionIdName = coerce

data EvolutionWorkspace = EvolutionWorkspace
  { knowledgeBase :: KnowledgeBase
  , workspace :: EvolutionId
  } deriving (Eq, Show)

data Before = Before
  { revision :: GitRevision
  , schema :: RootContract
  } deriving (Eq, Show)

data EvolutionContext = EvolutionContext
  { knowledgeBase :: KnowledgeBase
  , workspace :: EvolutionId
  , before :: Before
  , material :: WorkspaceSnapshot
  } deriving (Eq, Show)

newtype CapturedEvolution = CapturedEvolution EvolutionContext deriving (Eq, Show)
