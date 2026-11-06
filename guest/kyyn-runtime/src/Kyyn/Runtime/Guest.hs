{-# LANGUAGE AllowAmbiguousTypes, ScopedTypeVariables, TypeApplications, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Runtime.Guest (Entry, sourceConnectorEntry, sinkConnectorEntry, toolEntry, configurationEntry, loginEntry, sinkEntry, sinkDefaultsEntry, acquisitionEntry, capturedReadEntry, validationEntry, queryEntry, describeEntry, checkEntries, runGuest) where

import Control.Monad (unless)
import qualified Data.Aeson as Json
import qualified Data.Aeson.Types as Json
import qualified Data.ByteString as Bytes
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import Agentic.Aeson (toAeson, fromAeson)
import Kyyn.Contract
import Kyyn.Types.Guest
import Kyyn.Types.SchemaMetadata
import Kyyn.Types.Diagnostic (ValidationReport)
import Kyyn.Types.Query (Query)
import Kyyn.Runtime.Contract (runtimeCodec, fromWire, toWire)
import Kyyn.Plugin (CapturedRead)
import Kyyn.Types.Plugin (EvidenceSnapshot(..), FetchError)
import Kyyn.Runtime.Plugin (executeCapturedReadAction)
import Kyyn.Runtime.Query (executeQuery)
import Kyyn.Runtime.Validation (encodeReportValue)
import Kyyn.Runtime.ToolEntry (toolEntry)
import Kyyn.Runtime.PluginEntry (configurationEntry, loginEntry, sinkEntry, sinkDefaultsEntry)
import Kyyn.Runtime.AcquisitionEntry (acquisitionEntry)
import Kyyn.Runtime.Entry (Entry(..), Adapter(..), CapturedAdapter(..), entryActions, entryDescriptor, pureEntry, writeReply)
import Kyyn.Runtime.Transport

validationEntry :: forall root. Contract root => SchemaMetadata -> [Text]
  -> (root -> ValidationReport) -> Either ProjectionError Entry
validationEntry metadata sources validate = do
  compiled <- compileContract (contract @root)
  let description = describeContract compiled.description metadata sources
      run value = do
        root <- either (Left . Text.unpack) Right (compiled.codec.decode (fromAeson value))
        report <- encodeReportValue (validate root)
        pure (toAeson (fromWire report))
  pure (pureEntry (ValidatorEntry "validate" description) run)

queryEntry :: forall root args result. (Contract root, Contract args, Contract result)
  => Text -> (SchemaMetadata,[Text]) -> (SchemaMetadata,[Text]) -> (SchemaMetadata,[Text])
  -> (args -> Query root result) -> Either ProjectionError Entry
queryEntry name (rootMetadata,rootSources) (argumentMetadata,argumentSources) (resultMetadata,resultSources) selected = do
  root <- compileContract (contract @root)
  arguments <- compileContract (contract @args)
  result <- compileContract (contract @result)
  let description = QueryEntry name (QueryContracts
        (describeContract root.description rootMetadata rootSources)
        (describeContract arguments.description argumentMetadata argumentSources)
        (describeContract result.description resultMetadata resultSources))
      run value = do
        QueryInvocation rootValue argumentsValue <- Json.parseEither Json.parseJSON value
        reply <- executeQuery (runtimeCodec root.codec) (runtimeCodec arguments.codec) (runtimeCodec result.codec)
          selected (toWire (fromAeson rootValue)) (toWire (fromAeson argumentsValue))
        pure (toAeson (fromWire reply))
  pure (pureEntry description run)

capturedReadEntry :: forall args payload result. (Contract args, Contract payload, Contract result)
  => Text -> CapturedMethodIdentity -> [Text]
  -> (args -> EvidenceSnapshot payload -> CapturedRead payload (Either FetchError result))
  -> Either ProjectionError CapturedAdapter
capturedReadEntry name method sources selected = do
  arguments <- compileContract (contract @args)
  payload <- compileContract (contract @payload)
  result <- compileContract (contract @result)
  let describe compiled = describeContract compiled (SchemaMetadata [] [] []) sources
      description = Invocation name (CapturedContracts
        (describe arguments.description) (describe payload.description) (describe result.description))
      run transport value = do
        CapturedInvocation input snapshot <- either fail pure (Json.parseEither Json.parseJSON value)
        decoded <- either (fail . Text.unpack) pure (arguments.codec.decode (fromAeson input))
        executeCapturedReadAction transport (runtimeCodec payload.codec) (runtimeCodec result.codec)
          (selected decoded (EvidenceSnapshot snapshot))
  pure (CapturedAdapter method.methodName method.methodDescription (Adapter description run))

describeEntry :: forall value. Contract value => Text -> SchemaMetadata -> [Text] -> Either ProjectionError Entry
describeEntry name metadata sources = do
  compiled <- compileContract (contract @value)
  pure (pureEntry (ContractEntry name (describeContract compiled.description metadata sources))
    (const (Left "This entry describes a contract and cannot be invoked")))

sourceConnectorEntry :: ConnectorIdentity
  -> Either ProjectionError (Adapter DescribedContract)
  -> Either ProjectionError (Adapter (AcquisitionContracts DescribedContract))
  -> Maybe (Either ProjectionError (Adapter DescribedContract))
  -> [Either ProjectionError CapturedAdapter] -> Either ProjectionError Entry
sourceConnectorEntry ident configuration acquisition authentication captured = do
  Adapter config runConfiguration <- configuration
  Adapter acquisitionDescription fetch <- acquisition
  authenticationAdapter <- traverse id authentication
  capturedAdapters <- sequence captured
  let description = SourceEntries config acquisitionDescription (fmap (\(Adapter invocation _) -> invocation) authenticationAdapter)
        [CapturedEntry name documentation invocation | CapturedAdapter name documentation (Adapter invocation _) <- capturedAdapters]
      actions = [(config.invocationName,runConfiguration),(acquisitionDescription.invocationName,fetch)] ++
        [(invocation.invocationName,run) | Just (Adapter invocation run) <- [authenticationAdapter]] ++
        [(invocation.invocationName,run) | CapturedAdapter _ _ (Adapter invocation run) <- capturedAdapters]
  pure (ConnectorGroup (ConnectorEntry ident description) actions)

sinkConnectorEntry :: ConnectorIdentity
  -> Either ProjectionError (Adapter DescribedContract)
  -> Either ProjectionError (Adapter (SinkContracts DescribedContract))
  -> Either ProjectionError (Adapter DescribedContract) -> Either ProjectionError Entry
sinkConnectorEntry ident configuration publication options = do
  Adapter config runConfiguration <- configuration
  Adapter publicationDescription run <- publication
  Adapter defaultsDescription getDefaults <- options
  pure (ConnectorGroup (ConnectorEntry ident (SinkEntries config publicationDescription defaultsDescription))
    [(config.invocationName,runConfiguration),(publicationDescription.invocationName,run),(defaultsDescription.invocationName,getDefaults)])

buildEntries :: [Either ProjectionError Entry] -> IO [Entry]
buildEntries selected = do
  built <- either (fail . show) pure (sequence selected)
  let descriptions = map entryDescriptor built
      names = concatMap entryNames descriptions
  unless (length names == length (nub names)) (fail "Duplicate guest entry names")
  pure built

-- The build helper forces the same contracts before publishing its executable.
checkEntries :: [Either ProjectionError Entry] -> IO ()
checkEntries selected = buildEntries selected >> pure ()

runGuest :: [ModuleDescription] -> [Either ProjectionError Entry] -> IO ()
runGuest exports selected = do
  built <- buildEntries selected
  let descriptions = map entryDescriptor built
  withTransport $ \transport -> do
    (metadata,body) <- readFrame transport
    unless (Bytes.null body) (fail "Unexpected invocation body")
    request <- either fail pure (Json.eitherDecodeStrict' metadata)
    case request of
      Describe -> writeReply transport (Json.toJSON (GuestDescription protocolIdentity descriptions exports))
      Invoke name argument -> case [run | (selectedName,run) <- concatMap entryActions built, selectedName == name] of
        [run] -> run transport argument
        _ -> fail "Unknown guest entry"
