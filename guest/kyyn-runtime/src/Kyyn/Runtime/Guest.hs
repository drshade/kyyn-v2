{-# LANGUAGE AllowAmbiguousTypes, ScopedTypeVariables, TypeApplications, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Runtime.Guest (Entry, acquisitionEntry, capturedReadEntry, validationEntry, queryEntry, describeEntry, checkEntries, runGuest) where

import Control.Monad (unless)
import qualified Data.Aeson as Json
import qualified Data.Aeson.Types as Json
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Agentic.Aeson (toAeson, fromAeson)
import Kyyn.Contract
import Kyyn.Types.Guest
import Kyyn.Types.SchemaMetadata
import Kyyn.Types.Diagnostic (ValidationReport)
import Kyyn.Types.Query (Query)
import Kyyn.Runtime.Contract (runtimeCodec, fromWire)
import Kyyn.Plugin (CapturedRead)
import Kyyn.Types.Plugin (EvidenceSnapshot(..), FetchError)
import Kyyn.Runtime.Plugin (executeCapturedReadAction)
import Kyyn.Runtime.Query (executeQuery)
import Kyyn.Runtime.Validation (encodeReportValue)
import Kyyn.Runtime.AcquisitionEntry (acquisitionEntry)
import Kyyn.Runtime.Entry (Entry(..), pureEntry, writeReply)
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
        reply <- executeQuery (runtimeCodec root.codec) (runtimeCodec arguments.codec) (runtimeCodec result.codec)
          selected (Text.unpack (Text.decodeUtf8 (Lazy.toStrict (Json.encode value))))
        pure (toAeson (fromWire reply))
  pure (pureEntry description run)

capturedReadEntry :: forall args payload result. (Contract args, Contract payload, Contract result)
  => Text -> CapturedMethodIdentity -> [Text]
  -> (args -> EvidenceSnapshot payload -> CapturedRead payload (Either FetchError result))
  -> Either ProjectionError Entry
capturedReadEntry name method sources selected = do
  arguments <- compileContract (contract @args)
  payload <- compileContract (contract @payload)
  result <- compileContract (contract @result)
  let describe compiled = describeContract compiled (SchemaMetadata [] [] []) sources
      description = CapturedReadEntry name method (CapturedContracts
        (describe arguments.description) (describe payload.description) (describe result.description))
      run transport value = do
        CapturedInvocation input snapshot <- either fail pure (Json.parseEither Json.parseJSON value)
        decoded <- either (fail . Text.unpack) pure (arguments.codec.decode (fromAeson input))
        executeCapturedReadAction transport (runtimeCodec payload.codec) (runtimeCodec result.codec)
          (selected decoded (EvidenceSnapshot snapshot))
  pure (Entry description run)

describeEntry :: forall value. Contract value => Text -> SchemaMetadata -> [Text] -> Either ProjectionError Entry
describeEntry name metadata sources = do
  compiled <- compileContract (contract @value)
  pure (pureEntry (ContractEntry name (describeContract compiled.description metadata sources))
    (const (Left "This entry describes a contract and cannot be invoked")))

buildEntries :: [Either ProjectionError Entry] -> IO [Entry]
buildEntries selected = do
  built <- either (fail . show) pure (sequence selected)
  let descriptions = [description | Entry description _ <- built]
      names = map entryName descriptions
  unless (length names == length (nub names)) (fail "Duplicate guest entry names")
  pure built

-- The build helper forces the same contracts before publishing its executable.
checkEntries :: [Either ProjectionError Entry] -> IO ()
checkEntries selected = buildEntries selected >> pure ()

runGuest :: [ModuleDescription] -> [Either ProjectionError Entry] -> IO ()
runGuest exports selected = do
  built <- buildEntries selected
  let descriptions = [description | Entry description _ <- built]
  withTransport $ \transport -> do
    (metadata,body) <- readFrame transport
    unless (Bytes.null body) (fail "Unexpected invocation body")
    request <- either fail pure (Json.eitherDecodeStrict' metadata)
    case request of
      Describe -> writeReply transport (Json.toJSON (GuestDescription protocolIdentity descriptions exports))
      Invoke name argument -> case [run | Entry description run <- built, description.entryName == name] of
        [run] -> run transport argument
        _ -> fail "Unknown guest entry"
