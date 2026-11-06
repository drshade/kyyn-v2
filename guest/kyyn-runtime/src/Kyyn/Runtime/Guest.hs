{-# LANGUAGE AllowAmbiguousTypes, ScopedTypeVariables, TypeApplications, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Runtime.Guest (Entry, validationEntry, queryEntry, describeEntry, runGuest) where

import Control.Monad (unless)
import qualified Data.Aeson as Json
import qualified Data.Aeson.Types as Json
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.List (nub, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Agentic.Aeson (toAeson, fromAeson)
import Kyyn.Contract
import Kyyn.Types.Guest
import Kyyn.Types.SchemaMetadata
import Kyyn.Types.Diagnostic (ValidationReport)
import Kyyn.Types.Query (Query)
import qualified Kyyn.Runtime.Json as Wire
import Kyyn.Runtime.Contract (runtimeCodec, fromWire, toWire)
import Kyyn.Runtime.Query (executeQuery)
import Kyyn.Runtime.Validation (encodeReportValue)
import Kyyn.Runtime.Transport

-- Generated adapters construct entries only after their contracts compile.
data Entry = Entry EntryDescription (Json.Value -> Either String Json.Value)

validationEntry :: forall root. Contract root => SchemaMetadata -> [Text]
  -> (root -> ValidationReport) -> Either ProjectionError Entry
validationEntry metadata sources validate = do
  compiled <- compileContract (contract @root)
  let description = describeContract compiled.description metadata sources
      run value = do
        root <- either (Left . Text.unpack) Right (compiled.codec.decode (fromAeson value))
        report <- encodeReportValue (validate root)
        pure (toAeson (fromWire report))
  pure (Entry (EntryDescription "validate" "validator" [("root",description)] []) run)

queryEntry :: forall root args result. (Contract root, Contract args, Contract result)
  => Text -> SchemaMetadata -> [Text] -> (args -> Query root result) -> Either ProjectionError Entry
queryEntry name metadata sources selected = do
  root <- compileContract (contract @root)
  arguments <- compileContract (contract @args)
  result <- compileContract (contract @result)
  let plain structure = describeContract structure (SchemaMetadata [] [] []) sources
      description = EntryDescription name "query"
        [("root",describeContract root.description metadata sources),
         ("arguments",plain arguments.description),("result",plain result.description)] ["snapshot-read"]
      run value = do
        reply <- executeQuery (runtimeCodec root.codec) (runtimeCodec arguments.codec) (runtimeCodec result.codec)
          selected (Text.unpack (Text.decodeUtf8 (Lazy.toStrict (Json.encode value))))
        pure (toAeson (fromWire reply))
  pure (Entry description run)

describeEntry :: forall value. Contract value => Text -> SchemaMetadata -> [Text] -> Either ProjectionError Entry
describeEntry name metadata sources = do
  compiled <- compileContract (contract @value)
  pure (Entry (EntryDescription name "contract" [("value",describeContract compiled.description metadata sources)] [])
    (const (Left "This entry describes a contract and cannot be invoked")))

runGuest :: [ExportDescription] -> [Either ProjectionError Entry] -> IO ()
runGuest exports selected = do
  built <- either (fail . show) pure (sequence selected)
  let descriptions = [description | Entry description _ <- built]
      names = map entryName descriptions
  unless (length names == length (nub names)) (fail "Duplicate guest entry names")
  withTransport $ \transport -> do
    (metadata,body) <- readFrame transport
    unless (Bytes.null body) (fail "Unexpected invocation body")
    request <- either fail pure (Json.eitherDecodeStrict' metadata)
    reply <- case request of
      Json.Object fields -> do
        operation <- either fail pure (Json.parseEither (Json..: "operation") fields)
        case operation :: Text of
          "describe" -> do
            unless (Keys.keys fields == ["operation"]) (fail "Description takes no arguments")
            pure (Json.toJSON (GuestDescription protocolIdentity descriptions exports))
          "invoke" -> do
            unless (sort (Keys.keys fields) == ["argument","entry","operation"]) (fail "Malformed invocation")
            name <- either fail pure (Json.parseEither (Json..: "entry") fields)
            argument <- either fail pure (Json.parseEither (Json..: "argument") fields)
            case [run | Entry description run <- built, description.entryName == name] of
              [run] -> either fail pure (run argument)
              _ -> fail "Unknown guest entry"
          _ -> fail "Unknown guest operation"
      _ -> fail "Expected guest request object"
    -- The wire profile is checked before emitting a frame.
    encoded <- either fail pure (Wire.printValue (toWire (fromAeson reply)))
    writeJson transport encoded
