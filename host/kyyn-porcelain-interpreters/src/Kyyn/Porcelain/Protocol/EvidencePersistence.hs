module Kyyn.Porcelain.Protocol.EvidencePersistence
  ( encodeState, encodeStateWithPosition, decodePosition, decodeState, decodeHeader, EvidenceHeader(..) ) where

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

data EvidenceHeader = EvidenceHeader PackageIdentity String FetchId deriving (Eq, Show)

headerShape :: Shape
headerShape = Record [("producer",text),("contract",text),("current",text)]

stateShape :: Shape -> Shape
stateShape payload = Record [("header",headerShape),("values",members),("latest",fetchShape)]
  where
    evidence = Record [("fingerprint",text),("references",List text),("payload",payload)]
    members = List (Record [("id",text),("evidence",evidence)])

fetchShape :: Shape
fetchShape = Record [("fetchedAt",text),("added",Scalar IntegerScalar),("updated",Scalar IntegerScalar),("removed",Scalar IntegerScalar),("options",Optional text)]

text :: Shape
text = Scalar TextScalar

optional :: Maybe String -> Value
optional Nothing = object ["tag" .= ("None" :: String)]
optional (Just value) = object ["tag" .= ("Some" :: String),"value" .= value]

parseOptional :: Value -> Parser (Maybe String)
parseOptional = withObject "optional text" $ \fields -> do
  tag <- fields .: "tag"
  case tag :: String of
    "None" -> pure Nothing
    "Some" -> Just <$> fields .: "value"
    _ -> fail "Unknown optional tag"

parseHeader :: Value -> Parser EvidenceHeader
parseHeader = withObject "evidence header" $ \fields -> EvidenceHeader
  <$> (PackageIdentity <$> fields .: "producer") <*> fields .: "contract"
  <*> (FetchId <$> fields .: "current")

decodeHeader :: DhallHandling :> es => ByteString -> Eff es (Either EvidenceProblem EvidenceHeader)
decodeHeader bytes = case Text.decodeUtf8' bytes of
  Left problem -> pure (Left (InvalidEvidence (show problem)))
  Right source -> decode headerShape parseHeader ("let document = (\n" <> source <> "\n) in document.header")

encodeState :: DhallHandling :> es => EvidenceProducer -> CheckedContract -> EvidenceState CheckedValue
  -> Eff es (Either EvidenceProblem ByteString)
encodeState producer contract state = encodeStateWithPosition producer contract state Nothing

encodeStateWithPosition :: DhallHandling :> es => EvidenceProducer -> CheckedContract -> EvidenceState CheckedValue
  -> Maybe (CheckedContract,CheckedValue) -> Eff es (Either EvidenceProblem ByteString)
encodeStateWithPosition (EvidenceProducer (PackageIdentity producer) identity) contract state@(EvidenceState latest@(FetchSummary (FetchId currentKey) _ _ _ _ _) values) position
  | identity /= contractId contract = pure (Left ProducerContractChanged)
  | otherwise = case encodedValue of
      Left problem -> pure (Left problem)
      Right value -> do
        result <- encodeValue shape value
        pure $ either (Left . InvalidEvidence . show) (Right . Text.encodeUtf8) result
  where
    shape = case stateShape (contractShape contract) of
      Record fields -> Record (fields ++ [("position",Optional (positionShape (maybe (Record []) (contractShape . fst) position)))])
      other -> other
    encodedValue = do
      validateState state
      positionValue <- case position of
        Nothing -> pure (object ["tag" .= ("None" :: String)])
        Just (expected,CheckedValue actual value)
          | actual == contractId expected -> pure (object ["tag" .= ("Some" :: String),"value" .= object
              ["contract" .= contractFingerprint actual,"value" .= value]])
          | otherwise -> Left (InvalidEvidence "Sync position has the wrong contract")
      currentValues <- traverse member values
      pure (object ["header" .= object ["producer" .= producer,
        "contract" .= contractFingerprint identity,"current" .= currentKey],
        "values" .= currentValues,"latest" .= summary latest,"position" .= positionValue])
    evidence (Evidence (EvidenceFingerprint fingerprint) refs (CheckedValue actual value))
      | actual == identity = Right (object ["fingerprint" .= fingerprint,"references" .= refs,"payload" .= value])
      | otherwise = Left ProducerContractChanged
    member (EvidenceId key,value) = (\e -> object ["id" .= key,"evidence" .= e]) <$> evidence value
    summary (FetchSummary _ at added updated removed options) = object
      ["fetchedAt" .= at,"added" .= show added,"updated" .= show updated,"removed" .= show removed,"options" .= optional options]

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
          Right source -> decode (stateShape (contractShape contract)) parseState
            ("(" <> source <> "\n).{header,values,latest}")
  where
    evidence = withObject "evidence" $ \fields -> Evidence <$> (EvidenceFingerprint <$> fields .: "fingerprint")
      <*> fields .: "references" <*> (CheckedValue identity <$> fields .: "payload")
    member = withObject "evidence member" $ \fields -> (,)
      <$> (EvidenceId <$> fields .: "id") <*> (fields .: "evidence" >>= evidence)
    parseState = withObject "evidence state" $ \fields -> do
      EvidenceHeader _ _ current <- fields .: "header" >>= parseHeader
      values <- fields .: "values" >>= traverse member
      latest <- fields .: "latest" >>= withObject "latest fetch" (\entry -> do
        at <- entry .: "fetchedAt"
        let count name = do
              encoded <- entry .: name
              case reads encoded of
                [(number,"")] | number >= (0 :: Integer) -> pure number
                _ -> fail "Invalid fetch change count"
        FetchSummary current at <$> count "added" <*> count "updated" <*> count "removed"
          <*> (entry .: "options" >>= parseOptional))
      let state = EvidenceState latest values
      either (fail . show) pure (validateState state)
      pure state

positionShape :: Shape -> Shape
positionShape payload = Record [("contract",text),("value",payload)]

decodePosition :: DhallHandling :> es => CheckedContract -> ByteString
  -> Eff es (Either EvidenceProblem CheckedValue)
decodePosition contract bytes = case Text.decodeUtf8' bytes of
  Left problem -> pure (Left (InvalidEvidence (show problem)))
  Right source -> decode (Optional (positionShape (contractShape contract))) parser
    ("(" <> source <> "\n).position")
  where
    parser = withObject "sync position" $ \fields -> do
      tag <- fields .: "tag"
      if (tag :: String) /= "Some" then fail "Stateful capture has no sync position" else do
        value <- fields .: "value"
        withObject "checked sync position" (\entry -> do
          fingerprint <- entry .: "contract"
          if fingerprint /= contractFingerprint (contractId contract) then fail "Sync position contract changed"
          else CheckedValue (contractId contract) <$> entry .: "value") value

decode :: DhallHandling :> es => Shape -> (Value -> Parser a) -> Text.Text -> Eff es (Either EvidenceProblem a)
decode shape parser source = do
  result <- decodeValue shape source
  pure $ case result of
    Left problems -> Left (InvalidEvidence (show problems))
    Right value -> either (Left . InvalidEvidence) Right (parseEither parser value)
