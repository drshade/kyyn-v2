{-# LANGUAGE RankNTypes, ScopedTypeVariables, TypeApplications, OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Runtime.ToolEntry
  ( toolEntry, exchangeCaptured, exchangeEvidenceList, exchangeEvidenceRead ) where

import Text.JSON.Types (JSValue)
import Data.Text (Text)
import qualified Data.Text as Text
import Agentic.Aeson (fromAeson)
import Kyyn.Contract
import Kyyn.Types.Guest
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Types.Plugin (FetchError)
import Kyyn.Types.Evidence (EvidenceId, Evidence)
import Kyyn.Types.Program (Program)
import Kyyn.Runtime.Contract (runtimeCodec)
import Kyyn.Runtime.Entry (Entry(..))
import Kyyn.Runtime.Transport (Transport)
import Kyyn.Runtime.Plugin (execute, exchange, eitherCodec, evidenceCodec, identityCodec)
import qualified Kyyn.Runtime.Json as Wire

toolEntry :: forall input result calls. (Contract input, Contract result)
  => Text -> Text -> [Text] -> [Text]
  -> (forall a. Transport -> Integer -> calls a -> IO a)
  -> (input -> Program calls (Either FetchError result)) -> Either ProjectionError Entry
toolEntry name description inputSources resultSources dispatch selected = do
  input <- compileContract (contract @input)
  result <- compileContract (contract @result)
  let contracts = ToolContracts
        (describeContract input.description (SchemaMetadata [] [] []) inputSources)
        (describeContract result.description (SchemaMetadata [] [] []) resultSources)
      run transport value = do
        arguments <- either (fail . Text.unpack) pure (input.codec.decode (fromAeson value))
        execute transport (eitherCodec (runtimeCodec result.codec)) (dispatch transport) (selected arguments)
  pure (Entry (ToolEntry ("$tool." <> name) name description contracts) run)

exchangeCaptured :: forall input result. (Contract input, Contract result)
  => Transport -> Integer -> CapturedMethodIdentity -> Text -> input -> IO (Either FetchError result)
exchangeCaptured transport requestId method instanceName input = do
  arguments <- projectCodec @input
  result <- projectCodec @result
  exchange transport requestId "plugin" "read"
    (Wire.record (instanceFields (ConnectorIdentity method.pluginName method.connectorName) instanceName ++
      [("method",Wire.encodeWith Wire.textCodec method.methodName),("input",Wire.encodeWith arguments input)]))
    (eitherCodec result)

exchangeEvidenceList :: Transport -> Integer -> ConnectorIdentity -> Text -> IO (Either FetchError [EvidenceId])
exchangeEvidenceList transport requestId connector instanceName =
  exchange transport requestId "evidence" "list" (Wire.record (instanceFields connector instanceName))
    (eitherCodec (Wire.listCodec identityCodec))

exchangeEvidenceRead :: forall payload. Contract payload
  => Transport -> Integer -> ConnectorIdentity -> Text -> EvidenceId -> IO (Either FetchError (Maybe (Evidence payload)))
exchangeEvidenceRead transport requestId connector instanceName key = do
  payload <- projectCodec @payload
  exchange transport requestId "evidence" "read"
    (Wire.record (instanceFields connector instanceName ++ [("id",Wire.encodeWith identityCodec key)]))
    (eitherCodec (Wire.optionalCodec (evidenceCodec payload)))

instanceFields :: ConnectorIdentity -> Text -> [(String,JSValue)]
instanceFields (ConnectorIdentity plugin connector) instanceName =
  [("plugin",Wire.encodeWith Wire.textCodec plugin),("connectorType",Wire.encodeWith Wire.textCodec connector),
   ("instance",Wire.encodeWith Wire.textCodec instanceName)]

projectCodec :: forall a. Contract a => IO (Wire.Codec a)
projectCodec = either (fail . show) (pure . runtimeCodec) (compileWire (contract @a))
