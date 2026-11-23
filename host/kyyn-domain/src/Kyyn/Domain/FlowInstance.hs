{-# LANGUAGE DuplicateRecordFields, OverloadedRecordDot #-}
module Kyyn.Domain.FlowInstance
  ( FlowInstanceId, flowInstanceId, flowInstanceIdText, FlowOwner(..)
  , FlowProgress(..), FlowOutcome(..), ExecutionStatus(..), CancelScope(..), DeliveryOrigin(..), ReplyOrigin(..), DispatchState(..), EventAdapter(..)
  , FlowLaunch(..), FlowInstance(..), FlowWait(..), WaitKind(..), WaitStatus(..)
  , FlowDelivery(..), DeliveryOutcome(..), FlowStoreProblem(..)
  ) where

import Kyyn.Domain.RecipeRunId (RecipeRunId)
import Kyyn.Domain.FlowBundleId (FlowBundleId)
import Kyyn.Types.KnowledgeBase (RecipeId, EventReference)
import Kyyn.Types.EventWait (ReplyOrigin(..))
import Data.Aeson (Value)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Types.Contract (Description)
import Kyyn.Domain.Diagnostic (Diagnostic)

newtype FlowInstanceId = FlowInstanceId Text deriving (Eq, Ord, Show)
flowInstanceId :: Text -> Either String FlowInstanceId
flowInstanceId value
  | null characters || not (all valid characters) = Left "Invalid flow instance ID"
  | otherwise = Right (FlowInstanceId value)
  where
    characters = Text.unpack value
    valid c = isAsciiLower c || isAsciiUpper c || isDigit c || c == '-' || c == '_'
flowInstanceIdText :: FlowInstanceId -> Text
flowInstanceIdText (FlowInstanceId value) = value

data FlowOwner = Hosted FlowBundleId RecipeId | External deriving (Eq, Show)
data FlowProgress = FlowWaiting [(Text,Value,WaitKind)] | FlowReturned Value deriving (Eq, Show)
data FlowOutcome = Completed Value | Failed [Diagnostic] | Cancelled deriving (Eq, Show)
data ExecutionStatus = Runnable | Running | Waiting | Finished FlowOutcome deriving (Eq, Show)
data CancelScope = ThisFlow | FlowAndDescendants deriving (Eq, Show)
data DeliveryOrigin = ReceivedFrom ReplyOrigin | ChildCompletion FlowInstanceId deriving (Eq, Show)

-- The application validates and captures the execution description before start.
-- This store preserves it verbatim; reading status never loads its guest or secrets.
data FlowLaunch = FlowLaunch
  { revision :: Text, request :: Value, owner :: FlowOwner
  } deriving (Eq, Show)
data FlowInstance = FlowInstance
  { instanceId :: FlowInstanceId, parent :: Maybe FlowInstanceId
  , startKey :: Text, launch :: FlowLaunch, status :: ExecutionStatus
  , blocked :: [Diagnostic], retryRequired :: Bool, cancelDescendants :: Bool, waits :: [FlowWait]
  , deliveries :: [FlowDelivery], attempts :: [RecipeRunId]
  } deriving (Eq, Show)
data WaitKind = ReplyWait | ChildWait FlowInstanceId Description | EventWait EventReference deriving (Eq, Show)
data DispatchState = NotRequired | Pending | Started | DispatchCompleted deriving (Eq, Show)
data EventAdapter = EventAdapter
  { dispatch :: DispatchState, cursor :: Maybe Value, dispatchProblems :: [Diagnostic] }
  deriving (Eq, Show)
data FlowWait = FlowWait
  { waitId :: Text, descriptor :: Value, kind :: WaitKind, waitStatus :: WaitStatus, adapter :: Maybe EventAdapter
  } deriving (Eq, Show)
data WaitStatus = Open | Answered DeliveryOrigin Value | Closed deriving (Eq, Show)
data FlowDelivery = FlowDelivery
  { deliveryId :: Text, waitId :: Text, origin :: DeliveryOrigin, value :: Value
  , outcome :: Maybe DeliveryOutcome
  } deriving (Eq, Show)
data DeliveryOutcome = Accepted | Duplicate | Conflicting | Invalid Text | ClosedWait
  deriving (Eq, Show)
data FlowStoreProblem = MissingInstance | AlreadyFinished | CancelledAncestor
  | StartConflict | NotHosted | ExecutionBlocked | InvalidTransition Text
  deriving (Eq, Show)
