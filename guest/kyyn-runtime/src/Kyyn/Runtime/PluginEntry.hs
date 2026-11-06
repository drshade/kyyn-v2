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
import Kyyn.Runtime.Entry (Entry(..), pureEntry)
import Kyyn.Runtime.PluginHost (executeLoginAction)
import Kyyn.Runtime.Sink (executeSinkAction)
import Kyyn.Runtime.Validation (encodeReportValue)

configurationEntry :: forall config. Contract config => Text -> ConnectorIdentity -> [Text]
  -> (config -> ValidationReport) -> Either ProjectionError Entry
configurationEntry name connector sources validate = do
  config <- compileContract (contract @config)
  let run value = do
        configuration <- decode config value
        report <- encodeReportValue (validate configuration)
        pure (toAeson (fromWire report))
  pure (pureEntry (ConfigurationEntry name connector (describe sources config)) run)

loginEntry :: forall config. Contract config => Text -> ConnectorIdentity -> [Text]
  -> (config -> PluginLogin (Either LoginError ())) -> Either ProjectionError Entry
loginEntry name connector sources selected = do
  config <- compileContract (contract @config)
  let run transport value = do
        LoginInvocation input <- either fail pure (Json.parseEither Json.parseJSON value)
        configuration <- either fail pure (decode config input)
        executeLoginAction transport (selected configuration)
  pure (Entry (LoginEntry name connector (describe sources config)) run)

sinkEntry :: forall config options input result.
  (Contract config, Contract options, Contract input, Contract result)
  => Text -> ConnectorIdentity -> [Text]
  -> (config -> options -> input -> Sink (Either SinkError result)) -> Either ProjectionError Entry
sinkEntry name connector sources publish = do
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
  pure (Entry (SinkEntry name connector contracts) run)

sinkDefaultsEntry :: forall options. Contract options => Text -> ConnectorIdentity -> [Text]
  -> options -> Either ProjectionError Entry
sinkDefaultsEntry name connector sources defaults = do
  options <- compileContract (contract @options)
  unit <- compileContract (contract @())
  pure (pureEntry (SinkDefaultsEntry name connector (describe sources options)) (\value -> do
    () <- decode unit value
    pure (toAeson (options.codec.encode defaults))))

describe :: [Text] -> CompiledContract a -> DescribedContract
describe sources compiled = describeContract compiled.description (SchemaMetadata [] [] []) sources

decode :: CompiledContract a -> Json.Value -> Either String a
decode compiled = either (Left . Text.unpack) Right . compiled.codec.decode . fromAeson
