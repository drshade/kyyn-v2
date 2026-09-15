module Kyyn.Porcelain.Protocol.EvidencePersistence
  ( encodeState, decodeState, decodeHeader, EvidenceHeader(..) ) where

import Control.Monad (unless)
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
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)

data EvidenceHeader = EvidenceHeader PackageIdentity String (Maybe FetchId) (Maybe FetchId) [FetchId] deriving (Eq, Show)

headerShape :: Shape
headerShape = Record [("producer",text),("contract",text),("current",Optional text),("baseline",Optional text),("fetches",List text)]

stateShape :: Shape -> Shape
stateShape payload = Record [("header",headerShape),
  ("initial",members),("values",members),("history",List fetch)]
  where
    evidence = Record [("fingerprint",text),("references",List text),("payload",payload)]
    members = List (Record [("id",text),("evidence",evidence)])
    entry = Record [("id",text),("evidence",evidence)]
    change = Union [("New",Just entry),("Updated",Just entry),("Removed",Just text)]
    fetch = Record [("id",text),("previous",Optional text),("fetchedAt",text),("changes",List change)]

text :: Shape
text = Scalar TextScalar

optional :: Maybe FetchId -> Value
optional Nothing = object ["tag" .= ("None" :: String)]
optional (Just (FetchId value)) = object ["tag" .= ("Some" :: String),"value" .= value]

parseOptional :: Value -> Parser (Maybe FetchId)
parseOptional = withObject "fetch selection" $ \fields -> do
  tag <- fields .: "tag"
  case tag :: String of
    "None" -> pure Nothing
    "Some" -> Just . FetchId <$> fields .: "value"
    _ -> fail "Unknown optional tag"

parseHeader :: Value -> Parser EvidenceHeader
parseHeader = withObject "evidence header" $ \fields -> EvidenceHeader
  <$> (PackageIdentity <$> fields .: "producer") <*> fields .: "contract"
  <*> (fields .: "current" >>= parseOptional)
  <*> (fields .: "baseline" >>= parseOptional)
  <*> (map FetchId <$> fields .: "fetches")

decodeHeader :: DhallHandling :> es => ByteString -> Eff es (Either EvidenceProblem EvidenceHeader)
decodeHeader bytes = case Text.decodeUtf8' bytes of
  Left problem -> pure (Left (InvalidEvidence (show problem)))
  Right source -> decode headerShape parseHeader ("let document = (\n" <> source <> "\n) in document.header")

encodeState :: DhallHandling :> es => EvidenceProducer -> CheckedContract -> EvidenceState CheckedValue
  -> Eff es (Either EvidenceProblem ByteString)
encodeState (EvidenceProducer (PackageIdentity producer) identity) contract state@(EvidenceState baseline initial current values history)
  | identity /= contractId contract = pure (Left ProducerContractChanged)
  | otherwise = case encodedValue of
      Left problem -> pure (Left problem)
      Right value -> do
        result <- encodeValue (stateShape (contractShape contract)) value
        pure $ either (Left . InvalidEvidence . show) (Right . Text.encodeUtf8) result
  where
    encodedValue = do
      validateState state
      initialValues <- traverse member initial
      currentValues <- traverse member values
      fetchValues <- traverse fetch history
      pure (object ["header" .= object ["producer" .= producer,
        "contract" .= contractFingerprint identity,"current" .= optional current,"baseline" .= optional baseline,
        "fetches" .= [key | Fetch (FetchId key) _ _ _ <- history]],
        "initial" .= initialValues,"values" .= currentValues,"history" .= fetchValues])
    evidence (Evidence (EvidenceFingerprint fingerprint) refs (CheckedValue actual value))
      | actual == identity = Right (object ["fingerprint" .= fingerprint,"references" .= refs,"payload" .= value])
      | otherwise = Left ProducerContractChanged
    member (EvidenceId key,value) = (\e -> object ["id" .= key,"evidence" .= e]) <$> evidence value
    change (NewEvidence key value) = tagged "New" <$> member (key,value)
    change (UpdatedEvidence key value) = tagged "Updated" <$> member (key,value)
    change (RemovedEvidence (EvidenceId key)) = Right (object ["tag" .= ("Removed" :: String),"value" .= key])
    tagged :: String -> Value -> Value
    tagged tag value = object ["tag" .= tag,"value" .= value]
    fetch (Fetch (FetchId key) previous at changes) = (\entries -> object
      ["id" .= key,"previous" .= optional previous,"fetchedAt" .= at,"changes" .= entries]) <$> traverse change changes

decodeState :: DhallHandling :> es => EvidenceProducer -> CheckedContract -> ByteString
  -> Eff es (Either EvidenceProblem (EvidenceState CheckedValue))
decodeState (EvidenceProducer producer identity) contract bytes
  | identity /= contractId contract = pure (Left ProducerContractChanged)
  | otherwise = do
      header <- decodeHeader bytes
      case header of
        Left problem -> pure (Left problem)
        Right (EvidenceHeader selected fingerprint _ _ _) | selected /= producer || fingerprint /= contractFingerprint identity ->
          pure (Left ProducerContractChanged)
        Right _ -> case Text.decodeUtf8' bytes of
          Left problem -> pure (Left (InvalidEvidence (show problem)))
          Right source -> decode (stateShape (contractShape contract)) parseState source
  where
    evidence = withObject "evidence" $ \fields -> Evidence <$> (EvidenceFingerprint <$> fields .: "fingerprint") <*> fields .: "references"
      <*> (CheckedValue identity <$> fields .: "payload")
    member = withObject "evidence member" $ \fields -> (,)
      <$> (EvidenceId <$> fields .: "id") <*> (fields .: "evidence" >>= evidence)
    change = withObject "change" $ \fields -> do
      tag <- fields .: "tag"
      case tag :: String of
        "New" -> uncurry NewEvidence <$> (fields .: "value" >>= member)
        "Updated" -> uncurry UpdatedEvidence <$> (fields .: "value" >>= member)
        "Removed" -> RemovedEvidence . EvidenceId <$> fields .: "value"
        _ -> fail "Unknown change kind"
    fetch = withObject "fetch" $ \fields -> Fetch <$> (FetchId <$> fields .: "id")
      <*> (fields .: "previous" >>= parseOptional) <*> fields .: "fetchedAt"
      <*> (fields .: "changes" >>= traverse change)
    parseState = withObject "evidence state" $ \fields -> do
      EvidenceHeader _ _ current baseline keys <- fields .: "header" >>= parseHeader
      initial <- fields .: "initial" >>= traverse member
      values <- fields .: "values" >>= traverse member
      history <- fields .: "history" >>= traverse fetch
      unless (keys == [key | Fetch key _ _ _ <- history]) (fail "Fetch index disagrees with history")
      let state = EvidenceState baseline initial current values history
      either (fail . show) pure (validateState state)
      pure state

decode :: DhallHandling :> es => Shape -> (Value -> Parser a) -> Text.Text -> Eff es (Either EvidenceProblem a)
decode shape parser source = do
  result <- decodeValue shape source
  pure $ case result of
    Left problems -> Left (InvalidEvidence (show problems))
    Right value -> either (Left . InvalidEvidence) Right (parseEither parser value)
