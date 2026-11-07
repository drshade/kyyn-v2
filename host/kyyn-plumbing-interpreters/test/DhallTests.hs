-- Real Dhall schema/value conversion and validation at the format boundary.
-- No guest compiler or repository operations.

{-# LANGUAGE OverloadedStrings, TypeApplications, ScopedTypeVariables, AllowAmbiguousTypes, DeriveGeneric, DeriveAnyClass, DerivingStrategies, NoFieldSelectors #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value(..), eitherDecodeStrict', object, (.=), toJSON)
import Data.Aeson.Key (Key)
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.Text.Encoding as Text
import Data.Text (Text)
import qualified Data.ByteString.Lazy as Lazy
import qualified Dhall.Binary as Binary
import qualified Dhall.Core as Dhall
import qualified Dhall.Parser as Parser
import Effectful (runPureEff)
import Kyyn.Domain.DataType
import Kyyn.Plumbing.Capability.DhallHandling
import Kyyn.Domain.Contract
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Protocol.Description (descriptionShape, descriptionValue, parseDescription)
import qualified Kyyn.Types.Contract as D
import qualified Kyyn.Contract as Guest
import Kyyn.Types.Fact (Fact, FactId)
import Agentic.Questions (Probability)
import GHC.Generics (Generic)
import Kyyn.Types.SchemaMetadata

main :: IO ()
main = do
  forM_ ["[ { name = \"mail\", binding = \"mail\", connector = < Mail : { enabled : Bool } | Calendar : {} >.Mail { enabled = True } } ]",
      "[] : List { name : Text, binding : Text, connector : < Folder : { path : Text } > }",
      "{ count = +42, confidence = 8500, nothing = None Text, flags = [ True, False ] }"] $ \contents -> do
    (shape,value) <- either (fail . show) pure (runPureEff (runDhallHandling (inferValue contents)))
    encoded <- either (fail . show) pure (runPureEff (runDhallHandling (encodeValue shape value)))
    roundtrip <- either (fail . show) pure (runPureEff (runDhallHandling (decodeValue shape encoded)))
    unless (roundtrip == value) (fail "Inferred configuration changed during round trip")
  forM_ ["env:KYYN_CONFIG_IMPORT_MUST_NOT_RESOLVE", "1.25", "True : Text"] $ \contents ->
    case runPureEff (runDhallHandling (inferValue contents)) of
      Left _ -> pure ()
      Right _ -> fail "Invalid or unsupported inferred value accepted"
  imported <- either (fail . show) pure (Parser.exprFromText "fixture" "env:KYYN_BINARY_IMPORT_MUST_NOT_RESOLVE")
  let importBytes = Lazy.toStrict (Binary.encodeExpression (Dhall.denote imported))
  case runPureEff (runDhallHandling (decodeBinaryValue (Scalar TextScalar) importBytes)) of
    Left _ -> pure ()
    Right _ -> fail "Binary Dhall import accepted"
  let envelopeShape = Record [("header",Scalar BoolScalar),("body",Scalar TextScalar)]
      envelope = object ["header" .= True, "body" .= ("Snow 雪" :: Text)]
  envelopeBytes <- either (fail . show) pure (runPureEff (runDhallHandling (encodeBinaryValue envelopeShape envelope)))
  envelopeValue <- either (fail . show) pure (runPureEff (runDhallHandling
    (decodeBinaryEnvelope (Scalar BoolScalar) (const (Right (Scalar TextScalar))) envelopeBytes)))
  unless (envelopeValue == envelope) (fail "Descriptor-driven binary envelope changed")
  case runPureEff (runDhallHandling (decodeBinaryEnvelope (Scalar BoolScalar) (const (Right (Scalar IntegerScalar))) envelopeBytes)) of
    Left _ -> pure ()
    Right _ -> fail "Binary envelope ignored derived body type"
  forM_ ["", "not binary Dhall"] $ \bytes ->
    case runPureEff (runDhallHandling (decodeBinaryValue (Scalar TextScalar) bytes)) of
      Left _ -> pure ()
      Right _ -> fail "Malformed binary Dhall accepted"
  stringBytes <- either (fail . show) pure (runPureEff (runDhallHandling (encodeBinaryValue (Scalar TextScalar) (String "value"))))
  case runPureEff (runDhallHandling (decodeBinaryValue (Scalar BoolScalar) stringBytes)) of
    Left _ -> pure ()
    Right _ -> fail "Binary value ignored its expected type"
  let probability = Scalar ProbabilityScalar
  forM_ ["0", "8500", "10000"] $ \n -> do
    encoded <- either (fail . show) pure (runPureEff (runDhallHandling (encodeValue probability (String n))))
    decoded <- either (fail . show) pure (runPureEff (runDhallHandling (decodeValue probability encoded)))
    unless (decoded == String n && encoded == n <> "\n") (fail "Probability basis points changed")
  forM_ ["-1", "10001", "0.85", "8500.0"] $ \invalidSource ->
    case runPureEff (runDhallHandling (decodeValue probability invalidSource)) of
      Left _ -> pure ()
      Right _ -> fail "Invalid probability storage accepted"
  forM_ ["-1", "10001", "08500", "+8500", "0.85"] $ \value ->
    case runPureEff (runDhallHandling (encodeValue probability (String value))) of
      Left _ -> pure ()
      Right _ -> fail "Invalid probability wire encoded"
  forM_ [(described @()), D.OptionalDescription (described @()), D.ListDescription (described @()),
      (described @Probability), D.OptionalDescription (described @Probability), D.ListDescription (described @Probability)] $ \datatype -> do
    persisted <- either (fail . show) pure (runPureEff (runDhallHandling (encodeValue descriptionShape (descriptionValue datatype))))
    restored <- either (fail . show) pure (runPureEff (runDhallHandling (decodeValue descriptionShape persisted)))
    unless (parseEither parseDescription restored == Right datatype) (fail "Type descriptor changed")
  probabilityContract <- either (fail . show) pure (checkContract (described @Probability) (SchemaMetadata [] [] []))
  integerContract <- either (fail . show) pure (checkContract (described @Integer) (SchemaMetadata [] [] []))
  unless (contractId probabilityContract /= contractId integerContract) (fail "Probability and Integer identities collided")
  let choice = described @Choice
      fact = described @(Fact Text)
  forM_ [((described @()), object []), (D.ListDescription (described @()), toJSON [object [], object []]),
      (D.OptionalDescription (described @()), object ["tag" .= ("Some" :: Text), "value" .= object []]),
      ((described @Text), String "München 🦋"), ((described @Integer), String "9007199254740993123456789"),
      ((described @Bool), Bool True), (D.ListDescription (described @Integer), toJSON (["1", "-2"] :: [Text])),
      (D.ListDescription (described @Text), toJSON ([] :: [Text])),
      (D.OptionalDescription (described @Text), object ["tag" .= ("None" :: Text)]),
      (D.OptionalDescription (described @Text), object ["tag" .= ("Some" :: Text), "value" .= ("name" :: Text)]),
      (choice, object ["tag" .= ("All" :: Text)]),
      (choice, object ["tag" .= ("Named" :: Text), "value" .= object ["name" .= ("todo" :: Text)]]),
      (D.ListDescription fact, toJSON [object ["id" .= ("todo-001" :: Text), "value" .= ("task" :: Text)]])] $ \(valueType,value) -> do
    valueContract <- either (fail . show) pure (checkContract valueType (SchemaMetadata [] [] []))
    roundTrip valueContract value
  contract <- either (fail . show) pure (checkContract root (SchemaMetadata [] [] []))
  expected <- either fail pure (eitherDecodeStrict' (Text.encodeUtf8 expectedJson) :: Either String Value)
  let result = runPureEff (runDhallHandling (decodeValue (contractShape contract) source))
  checked <- either (fail . show) pure result
  unless (checked == expected) (fail (show (checked)))
  forM_ invalid $ \contents -> case runPureEff (runDhallHandling (decodeValue (contractShape contract) contents)) of
    Left _ -> pure ()
    Right _ -> fail ("Accepted invalid input: " ++ show contents)
  empty <- either (fail . show) pure (runPureEff (runDhallHandling (decodeValue (contractShape contract) emptySource)))
  expectedEmpty <- either fail pure (eitherDecodeStrict' (Text.encodeUtf8 emptyJson) :: Either String Value)
  unless (empty == expectedEmpty) (fail (show (empty)))
  collectionContract <- either (fail . show) pure
    (checkContract collectionRoot (SchemaMetadata [] [] [CollectionDecl "items" "items" [("parent", "items")]]))
  collectionValue <- either (fail . show) pure (runPureEff (runDhallHandling (decodeValue (contractShape collectionContract) collectionSource)))
  expectedCollection <- either fail pure (eitherDecodeStrict' (Text.encodeUtf8 collectionJson) :: Either String Value)
  unless (collectionValue == expectedCollection) (fail (show (collectionValue)))
  forM_ [expected, expectedEmpty, set "title" (String "quote: \" slash: \\ newline:\n${notAnImport} 🌍") expected] $
    roundTrip contract
  roundTrip collectionContract expectedCollection
  roundTrip collectionContract (object ["items" .= ([] :: [Value])])
  forM_ badWire $ \value -> case runPureEff (runDhallHandling (encodeValue (contractShape contract) value)) of
    Left _ -> pure ()
    Right _ -> fail ("Encoded invalid wire value: " ++ show value)
  forM_ ["+1", "01", "-0", "1.0", " 1", "1 ", "1e3", "", "--1"] $ \number ->
    rejectEncoding contract (set "count" (String number) expected)
  forM_ [Number 42, Null, String "yes"] $ \value ->
    rejectEncoding contract (set "active" value expected)
  forM_ [object ["tag" .= ("Open" :: Text), "value" .= True]
        ,object ["tag" .= ("Done" :: Text)]
        ,object ["tag" .= ("Unknown" :: Text)]
        ,object ["tag" .= ("Open" :: Text), "extra" .= True]] $ \value ->
    rejectEncoding contract (set "status" value expected)
  forM_ [Null, object ["tag" .= ("None" :: Text), "value" .= True]
        ,object ["tag" .= ("Some" :: Text)]] $ \value ->
    rejectEncoding contract (set "note" value expected)
  putStrLn "Dhall typed decoding, checked encoding and semantic round trips passed."

roundTrip :: CheckedContract -> Value -> IO ()
roundTrip contract value = do
  binary <- either (fail . show) pure (runPureEff (runDhallHandling (encodeBinaryValue (contractShape contract) value)))
  binaryDecoded <- either (fail . show) pure (runPureEff (runDhallHandling (decodeBinaryValue (contractShape contract) binary)))
  unless (binaryDecoded == value) (fail "Binary Dhall round trip changed value")
  rendered <- either (fail . show) pure (runPureEff (runDhallHandling (encodeValue (contractShape contract) value)))
  decoded <- either (fail . show) pure (runPureEff (runDhallHandling (decodeValue (contractShape contract) rendered)))
  unless (decoded == value)
    (fail ("Round trip changed value: " ++ show rendered))
  rerendered <- either (fail . show) pure (runPureEff (runDhallHandling (encodeValue (contractShape contract) (decoded))))
  unless (rendered == rerendered) (fail "Unstable Dhall rendering")

rejectEncoding :: CheckedContract -> Value -> IO ()
rejectEncoding contract value = case runPureEff (runDhallHandling (encodeValue (contractShape contract) value)) of
  Left _ -> pure ()
  Right _ -> fail ("Encoded invalid wire value: " ++ show value)

set :: Key -> Value -> Value -> Value
set key value (Object values) = Object (Keys.insert key value values)
set _ _ value = value

badWire :: [Value]
badWire = [Null, Number 1, String "not a root", object [], object ["extra" .= True]]

described :: forall a. Guest.Contract a => D.Description
described = case Guest.compileContract (Guest.contract @a) of
  Left problem -> error (show problem)
  Right (Guest.CompiledContract description _) -> description

data Choice = All | Named { name :: Text } deriving stock (Generic) deriving anyclass (Guest.Contract)
data Status = Open | Done Integer deriving stock (Generic) deriving anyclass (Guest.Contract)
data RecordRoot = RecordRoot
  { title :: Text, count :: Integer, active :: Bool, note :: Maybe Text, labels :: [Text], status :: Status, identity :: FactId }
  deriving stock (Generic) deriving anyclass (Guest.Contract)
data CollectionRoot = CollectionRoot { items :: [Fact Payload] } deriving stock (Generic) deriving anyclass (Guest.Contract)
data Payload = Payload { parent :: Maybe FactId, result :: Result } deriving stock (Generic) deriving anyclass (Guest.Contract)
data Result = Pending | Ready { notes :: [Maybe Text] } deriving stock (Generic) deriving anyclass (Guest.Contract)

root :: D.Description
root = described @RecordRoot

source :: Text
source = "let title = \"héllo 🌍\" in { title = title, count = -9007199254740993123456789, active = True, note = Some \"ok\", labels = [\"a\", \"b\"], status = < Open | Done : Integer >.Done +42, identity = \"todo-001\" }"

emptySource :: Text
emptySource = "{ title = \"\", count = +0, active = False, note = None Text, labels = [] : List Text, status = < Open | Done : Integer >.Open, identity = \"todo-002\" }"

expectedJson :: Text
expectedJson = "{\"title\":\"héllo 🌍\",\"count\":\"-9007199254740993123456789\",\"active\":true,\"note\":{\"tag\":\"Some\",\"value\":\"ok\"},\"labels\":[\"a\",\"b\"],\"status\":{\"tag\":\"Done\",\"value\":\"42\"},\"identity\":\"todo-001\"}"

invalid :: [Text]
invalid = ["{", "{ title = \"only one field\" }", "env:HOME", "./fact.dhall", "https://example.com/fact.dhall"
  , "let ignored = ./unused.dhall in " <> emptySource
  , "(" <> emptySource <> ") // { extra = True }"
  , "{ title = \"x\", count = 1, active = True, note = None Text, labels = [] : List Text, status = < Open | Done : Integer >.Open, identity = \"id\" }"]

emptyJson :: Text
emptyJson = "{\"title\":\"\",\"count\":\"0\",\"active\":false,\"note\":{\"tag\":\"None\"},\"labels\":[],\"status\":{\"tag\":\"Open\"},\"identity\":\"todo-002\"}"

collectionRoot :: D.Description
collectionRoot = described @CollectionRoot

collectionSource :: Text
collectionSource = "{ items = [{ id = \"one\", value = { parent = Some \"other\", result = < Pending | Ready : { notes : List (Optional Text) } >.Ready { notes = [Some \"hello\", None Text] } } }] }"

collectionJson :: Text
collectionJson = "{\"items\":[{\"id\":\"one\",\"value\":{\"parent\":{\"tag\":\"Some\",\"value\":\"other\"},\"result\":{\"tag\":\"Ready\",\"value\":{\"notes\":[{\"tag\":\"Some\",\"value\":\"hello\"},{\"tag\":\"None\"}]}}}}]}"
