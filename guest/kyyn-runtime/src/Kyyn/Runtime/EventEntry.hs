{-# LANGUAGE ScopedTypeVariables, TypeApplications, OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Runtime.EventEntry (eventPollEntry, eventDispatchEntry) where

import Data.Text (Text)
import Kyyn.Contract
import Kyyn.Plugin.Event
import Kyyn.Types.Plugin (FetchError)
import Kyyn.Types.Guest
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Runtime.Contract (runtimeCodec)
import Kyyn.Runtime.Entry (Adapter(..))
import Kyyn.Runtime.Event
import Kyyn.Runtime.Json (fields, field)

eventPollEntry :: forall config request cursor reply.
  (Contract config, Contract request, Contract cursor, Contract reply)
  => Text -> [Text] -> (config -> EventPoll request cursor -> LiveEvent (Either FetchError (EventBatch reply cursor)))
  -> Either ProjectionError (Adapter (EventContracts DescribedContract))
eventPollEntry name sources selected = do
  config <- compileContract (contract @config)
  request <- compileContract (contract @request)
  cursor <- compileContract (contract @cursor)
  reply <- compileContract (contract @reply)
  let contracts = EventContracts (describe sources config) (describe sources request) (describe sources cursor) (describe sources reply)
  pure (Adapter (Invocation name contracts) $ \transport value -> do
    members <- either fail pure (fields ["config","input"] value)
    configuration <- either fail pure (field "config" (runtimeCodec config.codec) members)
    input <- either fail pure (field "input" (pollCodec (runtimeCodec request.codec) (runtimeCodec cursor.codec)) members)
    executeNetworkAction transport (batchCodec (runtimeCodec reply.codec) (runtimeCodec cursor.codec)) (selected configuration input))

eventDispatchEntry :: forall config request cursor.
  (Contract config, Contract request, Contract cursor)
  => Text -> [Text] -> (config -> EventDispatch request -> LiveEvent (Either FetchError cursor))
  -> Either ProjectionError (Adapter (DispatchContracts DescribedContract))
eventDispatchEntry name sources selected = do
  config <- compileContract (contract @config)
  request <- compileContract (contract @request)
  cursor <- compileContract (contract @cursor)
  let contracts = DispatchContracts (describe sources config) (describe sources request) (describe sources cursor)
  pure (Adapter (Invocation name contracts) $ \transport value -> do
    members <- either fail pure (fields ["config","input"] value)
    configuration <- either fail pure (field "config" (runtimeCodec config.codec) members)
    input <- either fail pure (field "input" (dispatchCodec (runtimeCodec request.codec)) members)
    executeNetworkAction transport (runtimeCodec cursor.codec) (selected configuration input))

describe :: [Text] -> CompiledContract a -> DescribedContract
describe sources compiled = describeContract compiled.description (SchemaMetadata [] [] []) sources
