{-# LANGUAGE ScopedTypeVariables, TypeApplications, OverloadedRecordDot #-}
module Kyyn.Runtime.PluginEntry (configurationEntry, loginEntry, sinkEntry, sinkDefaultsEntry) where

import qualified Data.Aeson as Json
import qualified Data.Aeson.Types as Json
import Data.Text (Text)
import qualified Data.Text as Text
import Agentic.Aeson (fromAeson, toAeson)
import Kyyn.Contract
import Kyyn.Plugin.Host (PluginLogin, LoginError)
import Kyyn.Plugin.Sink (Sink, SinkError)
import Kyyn.Types.Diagnostic (ValidationReport)
import Kyyn.Types.Guest
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Runtime.Contract (runtimeCodec, fromWire)
import Kyyn.Runtime.Entry (Adapter(..), pureAdapter)
import Kyyn.Runtime.PluginHost (executeLoginAction)
import Kyyn.Runtime.Sink (executeSinkAction)
import Kyyn.Runtime.Validation (encodeReportValue)

configurationEntry :: forall config. Contract config => Text -> [Text]
  -> (config -> ValidationReport) -> Either ProjectionError (Adapter DescribedContract)
configurationEntry name sources validate = do
  config <- compileContract (contract @config)
  let run value = do
        configuration <- decode config value
        report <- encodeReportValue (validate configuration)
        pure (toAeson (fromWire report))
  pure (pureAdapter (Invocation name (describe sources config)) run)

loginEntry :: forall config. Contract config => Text -> [Text]
  -> (config -> PluginLogin (Either LoginError ())) -> Either ProjectionError (Adapter DescribedContract)
loginEntry name sources selected = do
  config <- compileContract (contract @config)
  let run transport value = do
        LoginInvocation input <- either fail pure (Json.parseEither Json.parseJSON value)
        configuration <- either fail pure (decode config input)
        executeLoginAction transport (selected configuration)
  pure (Adapter (Invocation name (describe sources config)) run)

sinkEntry :: forall config options input result.
  (Contract config, Contract options, Contract input, Contract result)
  => Text -> [Text]
  -> (config -> options -> input -> Sink (Either SinkError result)) -> Either ProjectionError (Adapter (SinkContracts DescribedContract))
sinkEntry name sources publish = do
  config <- compileContract (contract @config)
  options <- compileContract (contract @options)
  input <- compileContract (contract @input)
  result <- compileContract (contract @result)
  let contracts = SinkContracts (describe sources config) (describe sources options)
        (describe sources input) (describe sources result)
      run transport value = do
        SinkInvocation rawConfig rawOptions rawInput <- either fail pure (Json.parseEither Json.parseJSON value)
        configuration <- either fail pure (decode config rawConfig)
        selectedOptions <- either fail pure (decode options rawOptions)
        selectedInput <- either fail pure (decode input rawInput)
        executeSinkAction transport (runtimeCodec result.codec) (publish configuration selectedOptions selectedInput)
  pure (Adapter (Invocation name contracts) run)

sinkDefaultsEntry :: forall options. Contract options => Text -> [Text]
  -> options -> Either ProjectionError (Adapter DescribedContract)
sinkDefaultsEntry name sources defaults = do
  options <- compileContract (contract @options)
  pure (pureAdapter (Invocation name (describe sources options)) (\value -> do
    SinkDefaultsInvocation <- Json.parseEither Json.parseJSON value
    pure (toAeson (options.codec.encode defaults))))

describe :: [Text] -> CompiledContract a -> DescribedContract
describe sources compiled = describeContract compiled.description (SchemaMetadata [] [] []) sources

decode :: CompiledContract a -> Json.Value -> Either String a
decode compiled = either (Left . Text.unpack) Right . compiled.codec.decode . fromAeson
