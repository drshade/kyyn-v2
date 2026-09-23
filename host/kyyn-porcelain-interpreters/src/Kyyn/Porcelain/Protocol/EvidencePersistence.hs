module Kyyn.Porcelain.Protocol.EvidencePersistence
  ( encodeState, decodeState, decodeHeader, decodeHistory, EvidenceHeader(..) ) where

import Data.Aeson (Value, object, (.=), (.:))
import Data.Aeson.Types (Parser, parseEither, withObject)
import Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Contract (CheckedContract, contractShape, contractId, contractFingerprint)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Evidence
import Kyyn.Domain.Plugin (PackageIdentity(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)

data EvidenceHeader = EvidenceHeader PackageIdentity String FetchId deriving (Eq, Show)

headerShape :: Shape
headerShape = Record [("producer",text),("contract",text),("current",text)]

stateShape :: Shape -> Shape
stateShape payload = Record [("header",headerShape),("values",members),("history",List fetch)]
  where
    evidence = Record [("fingerprint",text),("references",List text),("payload",payload)]
    members = List (Record [("id",text),("evidence",evidence)])
    fetch = fetchShape

fetchShape :: Shape
fetchShape = Record [("id",text),("previous",Optional text),("fetchedAt",text),("changes",List marker)]
  where
    citation = Record ([(name,text) | name <- ["producer","connector","source"]] ++ [("references",List text)])
    marker = Record [("kind",Union [(name,Nothing) | name <- ["New","Updated","Removed"]]),
      ("id",text),("fingerprint",text),("citation",citation)]

text :: Shape
text = Scalar TextScalar

optional :: Maybe FetchId -> Value
optional Nothing = object ["tag" .= ("None" :: String)]
optional (Just (FetchId value)) = object ["tag" .= ("Some" :: String),"value" .= value]

parseOptional :: Value -> Parser (Maybe FetchId)
parseOptional = withObject "fetch cursor" $ \fields -> do
  tag <- fields .: "tag"
  case tag :: String of
    "None" -> pure Nothing
    "Some" -> Just . FetchId <$> fields .: "value"
    _ -> fail "Unknown optional tag"

parseHeader :: Value -> Parser EvidenceHeader
parseHeader = withObject "evidence header" $ \fields -> EvidenceHeader
  <$> (PackageIdentity <$> fields .: "producer") <*> fields .: "contract"
  <*> (FetchId <$> fields .: "current")

decodeHeader :: DhallHandling :> es => ByteString -> Eff es (Either EvidenceProblem EvidenceHeader)
decodeHeader bytes = case Text.decodeUtf8' bytes of
  Left problem -> pure (Left (InvalidEvidence (show problem)))
  Right source -> decode headerShape parseHeader ("let document = (\n" <> source <> "\n) in document.header")

decodeHistory :: DhallHandling :> es => ByteString
  -> Eff es (Either EvidenceProblem (EvidenceHeader, [Fetch]))
decodeHistory bytes = case Text.decodeUtf8' bytes of
  Left problem -> pure (Left (InvalidEvidence (show problem)))
  Right source -> decode (Record [("header",headerShape),("history",List fetchShape)])
    (withObject "Evidence history" $ \fields -> (,)
      <$> (fields .: "header" >>= parseHeader) <*> (fields .: "history" >>= traverse parseFetch))
    ("(" <> source <> "\n).{header,history}")

encodeState :: DhallHandling :> es => EvidenceProducer -> CheckedContract -> EvidenceState CheckedValue
  -> Eff es (Either EvidenceProblem ByteString)
encodeState (EvidenceProducer (PackageIdentity producer) identity) contract state@(EvidenceState current values history)
  | identity /= contractId contract = pure (Left ProducerContractChanged)
  | otherwise = case encodedValue of
      Left problem -> pure (Left problem)
      Right value -> do
        result <- encodeValue (stateShape (contractShape contract)) value
        pure $ either (Left . InvalidEvidence . show) (Right . Text.encodeUtf8) result
  where
    encodedValue = do
      validateState state
      FetchId currentKey <- maybe (Left (InvalidEvidence "A stored evidence state must have a fetch")) Right current
      currentValues <- traverse member values
      pure (object ["header" .= object ["producer" .= producer,
        "contract" .= contractFingerprint identity,"current" .= currentKey],
        "values" .= currentValues,"history" .= map fetch history])
    evidence (Evidence (EvidenceFingerprint fingerprint) refs (CheckedValue actual value))
      | actual == identity = Right (object ["fingerprint" .= fingerprint,"references" .= refs,"payload" .= value])
      | otherwise = Left ProducerContractChanged
    member (EvidenceId key,value) = (\e -> object ["id" .= key,"evidence" .= e]) <$> evidence value
    marker (EvidenceChangeMarker kind (EvidenceId key) (EvidenceFingerprint fingerprint) (EvidenceRef plugin connector source refs)) =
      object ["kind" .= object ["tag" .= show kind],"id" .= key,"fingerprint" .= fingerprint,
        "citation" .= object ["producer" .= plugin,"connector" .= connector,"source" .= source,"references" .= refs]]
    fetch (Fetch (FetchId key) previous at changes) = object
      ["id" .= key,"previous" .= optional previous,"fetchedAt" .= at,"changes" .= map marker changes]

decodeState :: DhallHandling :> es => EvidenceProducer -> CheckedContract -> ByteString
  -> Eff es (Either EvidenceProblem (EvidenceState CheckedValue))
decodeState (EvidenceProducer producer identity) contract bytes
  | identity /= contractId contract = pure (Left ProducerContractChanged)
  | otherwise = do
      header <- decodeHeader bytes
      case header of
        Left problem -> pure (Left problem)
        Right (EvidenceHeader selected fingerprint _) | selected /= producer || fingerprint /= contractFingerprint identity ->
          pure (Left ProducerContractChanged)
        Right _ -> case Text.decodeUtf8' bytes of
          Left problem -> pure (Left (InvalidEvidence (show problem)))
          Right source -> decode (stateShape (contractShape contract)) parseState source
  where
    evidence = withObject "evidence" $ \fields -> Evidence <$> (EvidenceFingerprint <$> fields .: "fingerprint")
      <*> fields .: "references" <*> (CheckedValue identity <$> fields .: "payload")
    member = withObject "evidence member" $ \fields -> (,)
      <$> (EvidenceId <$> fields .: "id") <*> (fields .: "evidence" >>= evidence)
    parseState = withObject "evidence state" $ \fields -> do
      EvidenceHeader _ _ current <- fields .: "header" >>= parseHeader
      values <- fields .: "values" >>= traverse member
      history <- fields .: "history" >>= traverse parseFetch
      let state = EvidenceState (Just current) values history
      either (fail . show) pure (validateState state)
      pure state

parseFetch :: Value -> Parser Fetch
parseFetch = withObject "fetch" $ \fields -> Fetch <$> (FetchId <$> fields .: "id")
  <*> (fields .: "previous" >>= parseOptional) <*> fields .: "fetchedAt"
  <*> (fields .: "changes" >>= traverse marker)
  where
    kind = withObject "change kind" $ \fields -> do
      tag <- fields .: "tag"
      case tag :: String of
        "New" -> pure New
        "Updated" -> pure Updated
        "Removed" -> pure Removed
        _ -> fail "Unknown change kind"
    citation = withObject "citation" $ \fields -> EvidenceRef <$> fields .: "producer" <*> fields .: "connector"
      <*> fields .: "source" <*> fields .: "references"
    marker = withObject "change marker" $ \fields -> EvidenceChangeMarker
      <$> (fields .: "kind" >>= kind) <*> (EvidenceId <$> fields .: "id")
      <*> (EvidenceFingerprint <$> fields .: "fingerprint") <*> (fields .: "citation" >>= citation)

decode :: DhallHandling :> es => Shape -> (Value -> Parser a) -> Text.Text -> Eff es (Either EvidenceProblem a)
decode shape parser source = do
  result <- decodeValue shape source
  pure $ case result of
    Left problems -> Left (InvalidEvidence (show problems))
    Right value -> either (Left . InvalidEvidence) Right (parseEither parser value)
