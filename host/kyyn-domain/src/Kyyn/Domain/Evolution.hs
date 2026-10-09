{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Domain.Evolution
  ( EvolutionId, evolutionId, evolutionIdName, nextEvolutionId, EvolutionName(..), EvolutionWorkspace(..), Before(..)
  , EvolutionContext(..), PreparedEvolution(..), CapturedEvolution(..)
  , After(..), EvaluatedEvolution(..), PreviewRejection(..), Candidate(..)
  , EvolutionFilter(..), EvolutionSummary(..)
  ) where

import Data.Coerce (coerce)
import Data.Char (isAsciiLower, toLower)
import Data.List (intercalate)
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Workspace (WorkspaceSnapshot, EvolutionState)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Domain.Root (Root, SourceRoot)
import Kyyn.Domain.Path (RelativePath)
import Kyyn.Domain.EvolutionReport (EvolutionReport)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Types.Evolution (EvolutionFailure)
import qualified Kyyn.Domain.Recipe as Value

newtype EvolutionId = EvolutionId String deriving (Eq, Show)
newtype EvolutionName = EvolutionName String deriving (Eq, Show)

data EvolutionFilter = AllEvolutions | ExcludeDrafts deriving (Eq, Show)
data EvolutionSummary = EvolutionSummary
  { workspace :: EvolutionWorkspace, name :: EvolutionName
  , state :: EvolutionState }
  deriving (Eq, Show)

evolutionId :: String -> Either String EvolutionId
evolutionId value
  | first : rest <- value, alphaNumeric first, all (\c -> alphaNumeric c || c == '-') rest = Right (EvolutionId value)
  | otherwise = Left "Evolution ID must start with a lowercase letter or digit and contain only lowercase letters, digits and hyphens"

evolutionIdName :: EvolutionId -> String
evolutionIdName = coerce

nextEvolutionId :: [EvolutionId] -> EvolutionName -> Either String EvolutionId
nextEvolutionId existing (EvolutionName name)
  | null slug = Left ("Evolution name must contain an ASCII letter or digit: " ++ show name)
  | next > 999999 = Left "Evolution sequence is exhausted at 999999"
  | otherwise = evolutionId (replicate (6 - length number) '0' ++ number ++ "-" ++ slug)
  where
    slug = intercalate "-" (words [if alphaNumeric lowered then lowered else ' ' | c <- name, let lowered = toLower c])
    next = 1 + maximum (0 : [read digits :: Integer |
      identity <- existing, let (digits,suffix) = splitAt 6 (evolutionIdName identity),
      length digits == 6, all asciiDigit digits, '-' : _ <- [suffix]])
    number = show next

alphaNumeric :: Char -> Bool
alphaNumeric c = isAsciiLower c || asciiDigit c

asciiDigit :: Char -> Bool
asciiDigit c = c >= '0' && c <= '9'

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

data PreparedEvolution = PreparedEvolution
  { context :: EvolutionContext, beforeSource :: SourceRoot, afterSource :: SourceRoot }
  deriving (Eq, Show)

data CapturedEvolution = CapturedEvolution
  { context :: EvolutionContext, input :: Root, sourceClosure :: [RelativePath], preparedAfter :: SourceRoot }
  deriving (Eq, Show)

data Candidate a = Candidate
  { context :: EvolutionContext, report :: EvolutionReport, value :: a }
  deriving (Eq, Show, Functor)

data After = After { schema :: RootContract } deriving (Eq, Show)
data EvaluatedEvolution = EvaluatedEvolution
  { captured :: CapturedEvolution, after :: After, value :: Value.KnowledgeBase CheckedValue Value.StoredRecipe, report :: EvolutionReport }
  deriving (Eq, Show)
data PreviewRejection
  = ProposedCodeRejected [Diagnostic]
  | EvolutionRejected EvolutionFailure
  deriving (Eq, Show)
