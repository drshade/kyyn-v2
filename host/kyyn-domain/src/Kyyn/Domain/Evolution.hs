{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Domain.Evolution
  ( EvolutionId, evolutionId, evolutionIdName, EvolutionName(..), EvolutionWorkspace(..), Before(..)
  , EvolutionContext(..), CapturedEvolution(..)
  , After(..), EvaluatedEvolution(..), PreviewRejection(..), Candidate(..)
  , EvolutionFilter(..), EvolutionSummary(..)
  ) where

import Data.Coerce (coerce)
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Workspace (WorkspaceSnapshot, EvolutionState)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Domain.EvolutionReport (EvolutionReport)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Types.Evolution (EvolutionFailure)

newtype EvolutionId = EvolutionId String deriving (Eq, Show)
newtype EvolutionName = EvolutionName String deriving (Eq, Show)

data EvolutionFilter = AllEvolutions | ExcludeDrafts deriving (Eq, Show)
data EvolutionSummary = EvolutionSummary
  { workspace :: EvolutionWorkspace, name :: EvolutionName
  , state :: EvolutionState, acceptingCommit :: Maybe GitRevision }
  deriving (Eq, Show)

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

data Candidate a = Candidate
  { context :: EvolutionContext, report :: EvolutionReport, value :: a }
  deriving (Eq, Show, Functor)

data After = After { schema :: RootContract } deriving (Eq, Show)
data EvaluatedEvolution = EvaluatedEvolution
  { captured :: CapturedEvolution, after :: After, value :: CheckedValue, report :: EvolutionReport }
  deriving (Eq, Show)
data PreviewRejection
  = ProposedCodeRejected [Diagnostic]
  | EvolutionRejected EvolutionFailure
  deriving (Eq, Show)
