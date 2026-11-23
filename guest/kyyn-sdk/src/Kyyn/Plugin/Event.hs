{-# LANGUAGE DuplicateRecordFields, TypeOperators #-}
-- | Dispatch and poll operations for an interactive event provider.
module Kyyn.Plugin.Event
  ( WaitId(..), EventIdentity(..), LiveEvent, EventDispatch(..), EventPoll(..), EventArrival(..), EventBatch(..) ) where

import Data.Text (Text)
import Kyyn.Types.Program (Program, (:+:))
import Kyyn.Types.PluginHost (Http, Secrets, Waiting)

-- | HTTP, named secrets and waiting within one adapter invocation.
type LiveEvent = Program (Http :+: (Secrets :+: Waiting))

newtype WaitId = WaitId Text deriving (Eq, Show)
newtype EventIdentity = EventIdentity Text deriving (Eq, Show)

-- | The stable wait identity is reused when a dispatch is retried.
data EventDispatch request = EventDispatch
  { waitIdentity :: WaitId, request :: request }
  deriving (Eq, Show)

-- | Nothing is used only for the initial poll of an event without dispatch.
data EventPoll request cursor = EventPoll
  { waitIdentity :: WaitId, request :: request, cursor :: Maybe cursor }
  deriving (Eq, Show)

-- | An identity assigned by the provider, stable across repeated polls.
data EventArrival reply = EventArrival
  { identity :: EventIdentity, value :: reply }
  deriving (Eq, Show)

-- | Arrivals and the next cursor are committed together by the host.
data EventBatch reply cursor = EventBatch
  { arrivals :: [EventArrival reply], cursor :: cursor }
  deriving (Eq, Show)
