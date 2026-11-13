{-# LANGUAGE OverloadedStrings, DuplicateRecordFields #-}
module Kyyn.Domain.RecipeRun
  ( RecipeRunId, recipeRunId, runIdText, PreparedRecipeRun(..), RecipeRunHeader(..)
  , RunEvent(..), RunEventBody(..), SequencedRunEvent(..), RecipeRunSummary(..), RecipeRunPage(..)
  , RunStatus(..), terminalStatus
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Aeson (Value)
import Data.Text (Text)
import Numeric.Natural (Natural)
import Kyyn.Domain.CompiledProgram (BuildIdentity)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evolution (EvolutionId)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Recipe (RecipeId)
import Kyyn.Types.KnowledgeBase (FlowEntryRef)

newtype RecipeRunId = RecipeRunId String deriving (Eq, Ord, Show)
recipeRunId :: String -> Either String RecipeRunId
recipeRunId name
  | not (null name) && all (\c -> isAsciiLower c || isAsciiUpper c || isDigit c || c == '-') name = Right (RecipeRunId name)
  | otherwise = Left "Run ID must contain only ASCII letters, digits and hyphens"
runIdText :: RecipeRunId -> String
runIdText (RecipeRunId value) = value

data PreparedRecipeRun = PreparedRecipeRun
  { knowledgeBase :: KnowledgeBase, recipe :: RecipeId, flow :: FlowEntryRef
  , before :: GitRevision, build :: BuildIdentity, graph :: Value, mermaid :: Text
  } deriving (Eq, Show)
data RecipeRunHeader = RecipeRunHeader
  { runId :: RecipeRunId, recipe :: RecipeId, flow :: FlowEntryRef
  , before :: GitRevision, build :: BuildIdentity, startedAt :: Text, graph :: Value, mermaid :: Text
  } deriving (Eq, Show)
data RunEventBody = FlowObserved Value | RunCompleted EvolutionId | RunFailed [Diagnostic] | RunCancelled
  deriving (Eq, Show)
data RunEvent = RunEvent { elapsedNanos :: Natural, body :: RunEventBody } deriving (Eq, Show)
data SequencedRunEvent = SequencedRunEvent Natural RunEvent deriving (Eq, Show)
data RunStatus = Active | Interrupted | Completed EvolutionId | Failed | Cancelled deriving (Eq, Show)
data RecipeRunSummary = RecipeRunSummary { header :: RecipeRunHeader, status :: RunStatus, eventCount :: Natural }
  deriving (Eq, Show)
data RecipeRunPage = RecipeRunPage
  { summary :: RecipeRunSummary, events :: [SequencedRunEvent], next :: Maybe Natural
  , more :: Bool, incompleteTail :: Bool
  } deriving (Eq, Show)
terminalStatus :: RunEventBody -> Maybe RunStatus
terminalStatus (FlowObserved _) = Nothing
terminalStatus (RunCompleted draft) = Just (Completed draft)
terminalStatus (RunFailed _) = Just Failed
terminalStatus RunCancelled = Just Cancelled
