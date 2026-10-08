module Kyyn.Porcelain.Protocol.EvidenceIndex
  ( IndexDocument(..), encodeIndex, decodeIndex, capturedIndex ) where

import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=), (.:))
import Data.Aeson.Types (Parser, parseEither, withObject, parseJSON)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Blob (blobValue, parseBlob, sdkBlobRefType)
import Kyyn.Domain.Contract (CheckedContract, rootType, checkContract, contractShape, contractId)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..), shapeOf)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Domain.EvidenceIndex
import Kyyn.Domain.Plugin (PackageIdentity(..), ConnectorTypeName(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeBinaryValue, decodeBinaryEnvelope)
import Kyyn.Plumbing.Protocol.DataType (dataTypeShape, dataTypeValue, parseDataType)
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))

data IndexDocument = IndexDocument PackageIdentity ConnectorTypeName CheckedContract
  (EvidenceState PayloadLocation) (Maybe (CheckedContract, CheckedValue)) deriving (Eq, Show)

capturedIndex :: ConnectorInstanceRef -> IndexDocument -> EvidenceIndex
capturedIndex instanceRef (IndexDocument package _ contract (EvidenceState latest@(FetchSummary fetchId _ _ _ _ _) values) _) =
  EvidenceIndex (EvidenceSnapshotRef instanceRef (EvidenceProducer package (contractId contract)) fetchId)
    latest contract (Map.fromList [(key,value) | (EvidenceId key,value) <- values])

headerShape :: Shape
headerShape = Record [("producer",text),("connector",text),("payloadType",dataTypeShape),("positionType",Optional dataTypeShape)]

bodyShape :: Maybe CheckedContract -> Shape
bodyShape position = Record
  [("latest",Record [("identity",text),("fetchedAt",text),("added",integer),("updated",integer),("removed",integer),("options",Optional text)])
  ,("values",List (Record [("id",text),("evidence",Record
    [("fingerprint",text),("externalReferences",List text),("payload",Union [("Available",Just locationShape),("Truncated",Nothing)])])]))
  ,("position",Optional (maybe (Record []) contractShape position))]
  where
    locationShape = Record [("sha256",text),("size",integer),("blobs",List (either error id (shapeOf sdkBlobRefType)))]

text, integer :: Shape
text = Scalar TextScalar
integer = Scalar IntegerScalar

encodeIndex :: DhallHandling :> es => IndexDocument -> Eff es (Either EvidenceProblem ByteString)
encodeIndex (IndexDocument (PackageIdentity producer) (ConnectorTypeName connector) contract state@(EvidenceState summary values) position) =
  case validateState state >> traverse_ validatePosition position of
    Left problem -> pure (Left problem)
    Right () -> do
      encoded <- encodeBinaryValue (Record [("header",headerShape),("body",bodyShape (fst <$> position))])
        (object ["header" .= object ["producer" .= producer,"connector" .= connector,
          "payloadType" .= dataTypeValue (rootType contract),"positionType" .= optional (dataTypeValue . rootType . fst) position],
          "body" .= object ["latest" .= summaryValue summary,"values" .= map member values,
            "position" .= optional (\(_,CheckedValue _ value) -> value) position]])
      pure (either (Left . InvalidEvidence . show) Right encoded)
  where
    validatePosition (expected,CheckedValue actual _) = unless (actual == contractId expected)
      (Left (InvalidEvidence "Sync position has the wrong contract"))
    member (EvidenceId key,Evidence (EvidenceFingerprint fingerprint) refs payload) = object
      ["id" .= key,"evidence" .= object ["fingerprint" .= fingerprint,"externalReferences" .= refs,
       "payload" .= case payload of
         Truncated -> tagged "Truncated" Nothing
         Available (PayloadLocation hash size blobs) -> tagged "Available" (Just (object
           ["sha256" .= hash,"size" .= show size,"blobs" .= map blobValue blobs]))]]
    traverse_ f = maybe (Right ()) f

decodeIndex :: DhallHandling :> es => ByteString -> Eff es (Either EvidenceProblem IndexDocument)
decodeIndex bytes = do
  decoded <- decodeBinaryEnvelope headerShape
    (either (Left . pure . errorDiagnostic "evidence.descriptor")
      (\(_,_,_,position) -> Right (bodyShape position)) . parseEither parseHeader) bytes
  pure $ case decoded of
    Left problems -> Left (InvalidEvidence (show problems))
    Right value -> either (Left . InvalidEvidence) Right (parseEither document value)
  where
    document = withObject "evidence index" $ \outer -> do
      (package,connector,contract,positionContract) <- outer .: "header" >>= parseHeader
      outer .: "body" >>= withObject "evidence body" (\body -> do
        summary <- body .: "latest" >>= parseSummary
        values <- body .: "values" >>= traverse member
        stored <- body .: "position" >>= parseOptional pure
        position <- case (positionContract,stored) of
          (Nothing,Nothing) -> pure Nothing
          (Just expected,Just value) -> pure (Just (expected,CheckedValue (contractId expected) value))
          _ -> fail "Position descriptor and value must both be present or absent"
        let state = EvidenceState summary values
        either (fail . show) pure (validateState state)
        pure (IndexDocument package connector contract state position))
    member = withObject "evidence member" $ \entry -> (,)
      <$> (EvidenceId <$> entry .: "id") <*> (entry .: "evidence" >>= withObject "evidence" (\e -> Evidence
        <$> (EvidenceFingerprint <$> e .: "fingerprint") <*> e .: "externalReferences"
        <*> (e .: "payload" >>= withObject "availability" (\p -> do
          tag <- p .: "tag"
          case tag :: String of
            "Truncated" -> pure Truncated
            "Available" -> Available <$> (p .: "value" >>= location)
            _ -> fail "Invalid payload availability"))))
    location = withObject "payload location" $ \v -> do
      hash <- v .: "sha256"
      size <- v .: "size" >>= nonnegative
      unless (Text.length hash == 64 && Text.all (`elem` ("0123456789abcdef" :: String)) hash)
        (fail "Invalid payload SHA-256")
      PayloadLocation hash size <$> (v .: "blobs" >>= traverse parseBlob)

parseHeader :: Value -> Parser (PackageIdentity, ConnectorTypeName, CheckedContract, Maybe CheckedContract)
parseHeader = withObject "evidence header" $ \header -> (,,,)
  <$> (PackageIdentity <$> header .: "producer") <*> (ConnectorTypeName <$> header .: "connector")
  <*> (header .: "payloadType" >>= descriptor) <*> (header .: "positionType" >>= parseOptional descriptor)
  where
    descriptor value = do
      datatype <- parseDataType value
      either (fail . show) pure (checkContract datatype (SchemaMetadata [] [] []))

summaryValue :: FetchSummary -> Value
summaryValue (FetchSummary (FetchId key) at added updated removed options) = object
  ["identity" .= key,"fetchedAt" .= at,"added" .= show added,"updated" .= show updated,"removed" .= show removed,
   "options" .= optional (String . Text.pack) options]

parseSummary :: Value -> Parser FetchSummary
parseSummary = withObject "fetch summary" $ \s -> FetchSummary
  <$> (FetchId <$> s .: "identity") <*> s .: "fetchedAt"
  <*> (s .: "added" >>= nonnegative) <*> (s .: "updated" >>= nonnegative) <*> (s .: "removed" >>= nonnegative)
  <*> (s .: "options" >>= parseOptional parseJSON)

nonnegative :: String -> Parser Integer
nonnegative encoded = case reads encoded of
  [(n,"")] | n >= 0 && show n == encoded -> pure n
  _ -> fail "Expected canonical nonnegative integer"

tagged :: String -> Maybe Value -> Value
tagged tag value = object (["tag" .= tag] ++ maybe [] (\v -> ["value" .= v]) value)

optional :: (a -> Value) -> Maybe a -> Value
optional encode = maybe (tagged "None" Nothing) (tagged "Some" . Just . encode)

parseOptional :: (Value -> Parser a) -> Value -> Parser (Maybe a)
parseOptional decode = withObject "optional" $ \v -> do
  tag <- v .: "tag"
  case tag :: String of
    "None" -> pure Nothing
    "Some" -> Just <$> (v .: "value" >>= decode)
    _ -> fail "Invalid optional tag"
