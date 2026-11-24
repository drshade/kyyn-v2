{-# LANGUAGE GADTs, TypeOperators, OverloadedStrings #-}
module Kyyn.Runtime.Event
  ( executeNetworkAction, dispatchCodec, pollCodec, batchCodec ) where

import Kyyn.Plugin.Event
import Kyyn.Types.Plugin (FetchError)
import Kyyn.Types.PluginHost (Http, Secrets, Waiting)
import Kyyn.Types.Program ((:+:)(..))
import Kyyn.Runtime.Json
import Kyyn.Runtime.Plugin (execute, eitherCodec)
import Kyyn.Runtime.PluginHost (httpRequest, secretRequest, waitingRequest)
import Kyyn.Runtime.Transport (Transport)

executeNetworkAction :: Transport -> Codec result -> LiveEvent (Either FetchError result) -> IO ()
executeNetworkAction channel result = execute channel (eitherCodec result) (handler channel)
  where
    handler :: Transport -> Integer -> (Http :+: (Secrets :+: Waiting)) a -> IO a
    handler transport identity (InLeft call) = httpRequest transport identity call
    handler transport identity (InRight (InLeft call)) = secretRequest transport identity call
    handler transport identity (InRight (InRight call)) = waitingRequest transport identity call

dispatchCodec :: Codec request -> Codec (EventDispatch request)
dispatchCodec requestCodec = Codec encode decode
  where
    encode (EventDispatch (WaitId identity) request) = record
      [("waitIdentity",encodeWith textCodec identity),("request",encodeWith requestCodec request)]
    decode value = do
      members <- fields ["waitIdentity","request"] value
      EventDispatch . WaitId <$> field "waitIdentity" textCodec members <*> field "request" requestCodec members

pollCodec :: Codec request -> Codec cursor -> Codec (EventPoll request cursor)
pollCodec requestCodec cursorCodec = Codec encode decode
  where
    encode (EventPoll (WaitId identity) request cursor) = record
      [("waitIdentity",encodeWith textCodec identity),("request",encodeWith requestCodec request),
       ("cursor",encodeWith (optionalCodec cursorCodec) cursor)]
    decode value = do
      members <- fields ["waitIdentity","request","cursor"] value
      EventPoll . WaitId <$> field "waitIdentity" textCodec members <*> field "request" requestCodec members
        <*> field "cursor" (optionalCodec cursorCodec) members

batchCodec :: Codec reply -> Codec cursor -> Codec (EventBatch reply cursor)
batchCodec replyCodec cursorCodec = Codec encode decode
  where
    encode (EventBatch arrivals cursor) = record
      [("arrivals",encodeWith (listCodec arrivalCodec) arrivals),("cursor",encodeWith cursorCodec cursor)]
    decode value = do
      members <- fields ["arrivals","cursor"] value
      EventBatch <$> field "arrivals" (listCodec arrivalCodec) members <*> field "cursor" cursorCodec members
    arrivalCodec = Codec
      (\(EventArrival (EventIdentity identity) value) -> record [("identity",encodeWith textCodec identity),("value",encodeWith replyCodec value)])
      (\value -> do
        members <- fields ["identity","value"] value
        EventArrival . EventIdentity <$> field "identity" textCodec members <*> field "value" replyCodec members)
