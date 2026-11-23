{-# LANGUAGE GADTs, TypeOperators, OverloadedStrings #-}
module Kyyn.Runtime.Event
  ( executeEventAction, dispatchCodec, pollCodec, batchCodec ) where

import Kyyn.Plugin.Event
import Kyyn.Types.Plugin (FetchError)
import Kyyn.Types.PluginHost (Http, Secrets, Waiting)
import Kyyn.Types.Program ((:+:)(..))
import Kyyn.Runtime.Json
import Kyyn.Runtime.Plugin (execute, eitherCodec)
import Kyyn.Runtime.PluginHost (httpRequest, secretRequest, waitingRequest)
import Kyyn.Runtime.Transport (Transport)

executeEventAction :: Transport -> Codec result -> LiveEvent (Either FetchError result) -> IO ()
executeEventAction channel result = execute channel (eitherCodec result) (handler channel)
  where
    handler :: Transport -> Integer -> (Http :+: (Secrets :+: Waiting)) a -> IO a
    handler transport identity (InLeft call) = httpRequest transport identity call
    handler transport identity (InRight (InLeft call)) = secretRequest transport identity call
    handler transport identity (InRight (InRight call)) = waitingRequest transport identity call

dispatchCodec :: Codec request -> Codec (EventDispatch request)
dispatchCodec requestCodec = Codec encode decode
  where
    encode (EventDispatch identity request) = record
      [("waitIdentity",encodeWith textCodec identity),("request",encodeWith requestCodec request)]
    decode value = do
      members <- fields ["waitIdentity","request"] value
      EventDispatch <$> field "waitIdentity" textCodec members <*> field "request" requestCodec members

pollCodec :: Codec request -> Codec cursor -> Codec (EventPoll request cursor)
pollCodec requestCodec cursorCodec = Codec encode decode
  where
    encode (EventPoll identity request cursor) = record
      [("waitIdentity",encodeWith textCodec identity),("request",encodeWith requestCodec request),
       ("cursor",encodeWith (optionalCodec cursorCodec) cursor)]
    decode value = do
      members <- fields ["waitIdentity","request","cursor"] value
      EventPoll <$> field "waitIdentity" textCodec members <*> field "request" requestCodec members
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
      (\(EventArrival identity value) -> record [("identity",encodeWith textCodec identity),("value",encodeWith replyCodec value)])
      (\value -> do
        members <- fields ["identity","value"] value
        EventArrival <$> field "identity" textCodec members <*> field "value" replyCodec members)
