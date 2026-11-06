{-# LANGUAGE FlexibleInstances, ScopedTypeVariables, TypeApplications, TypeOperators #-}
{-# LANGUAGE OverloadedRecordDot, OverloadedStrings #-}
-- Private adapter selection: these four disjoint heads are the supported fetch
-- signatures. GHC infers even non-exported provider types from the function.
module Kyyn.Runtime.AcquisitionEntry (acquisitionEntry) where

import Control.Monad (unless)
import qualified Data.Aeson as Json
import qualified Data.Aeson.Types as Json
import Data.Text (Text)
import qualified Data.Text as Text
import Agentic.Aeson (fromAeson)
import Kyyn.Contract
import Kyyn.Plugin.Host (Acquisition)
import Kyyn.Types.Plugin (EvidenceSnapshot(..), FetchError, FetchContext(..), FetchResult)
import Kyyn.Types.Evidence (EvidenceChange)
import Kyyn.Types.Guest
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Runtime.Contract (runtimeCodec)
import Kyyn.Runtime.Entry (Adapter(..))
import Kyyn.Runtime.Plugin (changeCodec, fetchResultCodec)
import Kyyn.Runtime.PluginHost (executeAcquisitionAction)
import qualified Kyyn.Runtime.Json as Wire

class AcquisitionFunction function where
  acquisitionEntry :: Text -> [Text] -> function -> Either ProjectionError (Adapter (AcquisitionContracts DescribedContract))

instance (Contract config, Contract payload) => AcquisitionFunction
  (config -> EvidenceSnapshot payload -> Acquisition payload (Either FetchError [EvidenceChange payload])) where
  acquisitionEntry name sources selected =
    makeAcquisition @config @payload name sources Nothing Nothing
      (\input -> noOptions input >> noContext input >> pure selected)
      (Wire.listCodec . changeCodec)

instance (Contract config, Contract options, Contract payload) => AcquisitionFunction
  (config -> Maybe options -> EvidenceSnapshot payload -> Acquisition payload (Either FetchError [EvidenceChange payload])) where
  acquisitionEntry name sources selected = do
    options <- compileContract (contract @options)
    makeAcquisition @config @payload name sources (Just (describe sources options)) Nothing
      (\input -> do
        noContext input
        decoded <- traverse (decode options) input.acquisitionOptions
        pure (\config -> selected config decoded))
      (Wire.listCodec . changeCodec)

instance (Contract config, Contract payload, Contract position, Contract report) => AcquisitionFunction
  (config -> FetchContext position -> EvidenceSnapshot payload -> Acquisition payload (Either FetchError (FetchResult payload position report))) where
  acquisitionEntry name sources selected = do
    position <- compileContract (contract @position)
    report <- compileContract (contract @report)
    makeAcquisition @config @payload name sources Nothing
      (Just (describe sources position,describe sources report))
      (\input -> do
        noOptions input
        context <- decodeContext position input
        pure (\config -> selected config context))
      (\payload -> fetchResultCodec payload (runtimeCodec position.codec) (runtimeCodec report.codec))

instance (Contract config, Contract options, Contract payload, Contract position, Contract report) => AcquisitionFunction
  (config -> Maybe options -> FetchContext position -> EvidenceSnapshot payload -> Acquisition payload (Either FetchError (FetchResult payload position report))) where
  acquisitionEntry name sources selected = do
    options <- compileContract (contract @options)
    position <- compileContract (contract @position)
    report <- compileContract (contract @report)
    makeAcquisition @config @payload name sources (Just (describe sources options))
      (Just (describe sources position,describe sources report))
      (\input -> do
        decoded <- traverse (decode options) input.acquisitionOptions
        context <- decodeContext position input
        pure (\config -> selected config decoded context))
      (\payload -> fetchResultCodec payload (runtimeCodec position.codec) (runtimeCodec report.codec))

makeAcquisition :: forall config payload result. (Contract config, Contract payload)
  => Text -> [Text] -> Maybe DescribedContract -> Maybe (DescribedContract,DescribedContract)
  -> (AcquisitionInvocation -> Either String
      (config -> EvidenceSnapshot payload -> Acquisition payload (Either FetchError result)))
  -> (Wire.Codec payload -> Wire.Codec result) -> Either ProjectionError (Adapter (AcquisitionContracts DescribedContract))
makeAcquisition name sources options state select resultCodec = do
  config <- compileContract (contract @config)
  payload <- compileContract (contract @payload)
  let contracts = case state of
        Nothing -> StatelessContracts (describe sources config) options (describe sources payload)
        Just (position,report) -> StatefulContracts (describe sources config) options (describe sources payload) position report
      run transport value = do
        input <- either fail pure (Json.parseEither Json.parseJSON value)
        configuration <- either fail pure (decode config input.acquisitionConfig)
        selected <- either fail pure (select input)
        executeAcquisitionAction transport input.acquisitionConcurrency (runtimeCodec payload.codec)
          (resultCodec (runtimeCodec payload.codec)) (selected configuration (EvidenceSnapshot input.acquisitionSnapshot))
  pure (Adapter (Invocation name contracts) run)

describe :: [Text] -> CompiledContract a -> DescribedContract
describe sources compiled = describeContract compiled.description (SchemaMetadata [] [] []) sources

decode :: CompiledContract a -> Json.Value -> Either String a
decode compiled = either (Left . Text.unpack) Right . compiled.codec.decode . fromAeson

noOptions :: AcquisitionInvocation -> Either String ()
noOptions input = unless (input.acquisitionOptions == Nothing) (Left "This connector takes no fetch options")

noContext :: AcquisitionInvocation -> Either String ()
noContext input = unless (input.acquisitionContext == Nothing) (Left "This connector takes no fetch context")

decodeContext :: CompiledContract position -> AcquisitionInvocation -> Either String (FetchContext position)
decodeContext position input = case input.acquisitionContext of
  Nothing -> Left "This connector requires a fetch context"
  Just context -> FetchContext context.acquisitionStartedAt <$> traverse (decode position) context.acquisitionPriorPosition
