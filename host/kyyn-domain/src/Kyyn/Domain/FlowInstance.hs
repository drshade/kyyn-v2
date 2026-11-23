{-# LANGUAGE DuplicateRecordFields, OverloadedRecordDot #-}
module Kyyn.Domain.FlowInstance
  ( FlowInstanceId, flowInstanceId, flowInstanceIdText, FlowOwner(..)
  , FlowOutcome(..), ExecutionStatus(..), CancelScope(..), ReplyOrigin(..)
  , FlowLaunch(..), FlowInstance(..), FlowWait(..), WaitStatus(..)
  , FlowDelivery(..), DeliveryOutcome(..), FlowStoreProblem(..)
  ) where

import Data.Aeson (Value)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import qualified Data.Text as Text
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

data FlowOwner = Hosted | External deriving (Eq, Show)
data FlowOutcome = Completed Value | Failed [Diagnostic] | Cancelled deriving (Eq, Show)
data ExecutionStatus = Runnable | Running | Waiting | Finished FlowOutcome deriving (Eq, Show)
data CancelScope = ThisFlow | FlowAndDescendants deriving (Eq, Show)
data ReplyOrigin = ManualReply Text | ProviderReply Text Text deriving (Eq, Show)

-- The application validates and captures the execution description before start.
-- This store preserves it verbatim; reading status never loads its guest or secrets.
data FlowLaunch = FlowLaunch
  { revision :: Text, request :: Value, captured :: Value, owner :: FlowOwner
  } deriving (Eq, Show)
data FlowInstance = FlowInstance
  { instanceId :: FlowInstanceId, parent :: Maybe FlowInstanceId
  , startKey :: Text, launch :: FlowLaunch, status :: ExecutionStatus
  , blocked :: [Diagnostic], cancelDescendants :: Bool, waits :: [FlowWait]
  , deliveries :: [FlowDelivery]
  } deriving (Eq, Show)
data FlowWait = FlowWait
  { waitId :: Text, descriptor :: Value, waitStatus :: WaitStatus
  } deriving (Eq, Show)
data WaitStatus = Open | Answered ReplyOrigin Value | Closed deriving (Eq, Show)
data FlowDelivery = FlowDelivery
  { deliveryId :: Text, waitId :: Text, origin :: ReplyOrigin, value :: Value
  , outcome :: Maybe DeliveryOutcome
  } deriving (Eq, Show)
data DeliveryOutcome = Accepted | Duplicate | Conflicting | Invalid Text | ClosedWait
  deriving (Eq, Show)
data FlowStoreProblem = MissingInstance | AlreadyFinished | CancelledAncestor
  | StartConflict | NotHosted | ExecutionBlocked | InvalidTransition Text
  deriving (Eq, Show)
