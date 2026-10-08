{-# LANGUAGE GADTs, TypeOperators, RankNTypes, ScopedTypeVariables #-}
module Kyyn.Runtime.Plugin (executeCapturedRead, execute, exchange, exchangeBody, eitherCodec, withOptionsCodec, withContextCodec, fetchResultCodec, input, fileRequest, evidenceRequest, identityCodec, evidenceCodec, changeCodec, blobCodec) where

import Kyyn.Runtime.Json
import Kyyn.Types.Evidence (EvidenceId(..), EvidenceFingerprint(..), EvidencePayload(..), Evidence(..), EvidenceChange(..))
import Kyyn.Types.Plugin
import Kyyn.Types.Blob
import Kyyn.Types.Program
import Kyyn.Runtime.Transport
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Text.JSON.Types (JSValue)

withOptionsCodec :: Codec config -> Codec options -> Codec (config, Maybe options)
withOptionsCodec configCodec optionsCodec = Codec encode decode
  where
    encode (config,options) = record [("config",encodeWith configCodec config),
      ("options",encodeWith (optionalCodec optionsCodec) options)]
    decode value = do
      values <- fields ["config","options"] value
      (,) <$> field "config" configCodec values <*> field "options" (optionalCodec optionsCodec) values

withContextCodec :: Codec arguments -> Codec position -> Codec (arguments, FetchContext position)
withContextCodec argumentsCodec positionCodec = Codec encode decode
  where
    encode (arguments,FetchContext at prior) = record
      [("input",encodeWith argumentsCodec arguments),("startedAt",encodeWith textCodec at),
       ("priorPosition",encodeWith (optionalCodec positionCodec) prior)]
    decode value = do
      values <- fields ["input","startedAt","priorPosition"] value
      (,) <$> field "input" argumentsCodec values
          <*> (FetchContext <$> field "startedAt" textCodec values <*> field "priorPosition" (optionalCodec positionCodec) values)

fetchResultCodec :: Codec payload -> Codec position -> Codec (FetchResult payload position)
fetchResultCodec payloadCodec positionCodec = Codec encode decode
  where
    encode (FetchResult changes position) = record
      [("changes",encodeWith (listCodec (changeCodec payloadCodec)) changes),("position",encodeWith positionCodec position)]
    decode value = do
      values <- fields ["changes","position"] value
      FetchResult <$> field "changes" (listCodec (changeCodec payloadCodec)) values <*> field "position" positionCodec values

executeCapturedRead :: forall arguments payload result. Codec arguments -> Codec payload -> Codec result
  -> (arguments -> EvidenceSnapshot payload -> Program (EvidenceRead payload :+: BlobRead) (Either FetchError result)) -> IO ()
executeCapturedRead argumentCodec payloadCodec resultCodec selected = withTransport $ \transport -> do
  (arguments, snapshot) <- input transport argumentCodec
  execute transport (eitherCodec resultCodec) (handler transport) (selected arguments snapshot)
  where
    handler :: Transport -> Integer -> (EvidenceRead payload :+: BlobRead) a -> IO a
    handler transport identity (InLeft call) = evidenceRequest transport payloadCodec identity call
    handler transport identity (InRight (ReadBlob ref)) = do
      (reply,raw) <- exchangeBody transport identity "blobs" "read" (encodeWith blobCodec ref) B.empty
      result <- either fail pure (decodeWith (eitherCodec (Codec (const (record [])) (\value -> fields [] value >> Right ()))) reply)
      case result of
        Left problem | B.null raw -> pure (Left problem)
                     | otherwise -> fail "Raw body accompanies failed blob read"
        Right () -> pure (Right raw)

blobCodec :: Codec BlobRef
blobCodec = Codec encode decode
  where
    encode (BlobRef hash size media name) = record
      [("sha256",encodeWith textCodec hash),("size",encodeWith integerCodec size),
       ("mediaType",encodeWith textCodec media),("name",encodeWith (optionalCodec textCodec) name)]
    decode value = do
      values <- fields ["sha256","size","mediaType","name"] value
      BlobRef <$> field "sha256" textCodec values <*> field "size" integerCodec values
        <*> field "mediaType" textCodec values <*> field "name" (optionalCodec textCodec) values

input :: Transport -> Codec a -> IO (a, EvidenceSnapshot payload)
input transport codec = do
  line <- readJson transport
  either fail pure $ do
    values <- parseValue line >>= fields ["arguments","snapshot"]
    arguments <- field "arguments" codec values
    snapshot <- EvidenceSnapshot <$> field "snapshot" textCodec values
    pure (arguments,snapshot)

execute :: Transport -> Codec result -> (forall a. Integer -> request a -> IO a) -> Program request result -> IO ()
execute transport codec handler = go 1
  where
    go _ (Pure result) = emit transport (record [("tag",encodeWith stringCodec "Completed"),("result",encodeWith codec result)])
    go identity (Request operation next) = handler identity operation >>= go (identity + 1) . next

fileRequest :: Transport -> Integer -> FileRead a -> IO a
fileRequest transport identity (ListFiles directory recursive) = exchange transport identity "files" "list"
  (record [("directory",encodeWith stringCodec directory),("recursive",encodeWith boolCodec recursive)])
  (eitherCodec (listCodec stringCodec))
fileRequest transport identity (ReadTextFile path) = exchange transport identity "files" "read"
  (record [("path",encodeWith stringCodec path)]) (eitherCodec capturedTextCodec)

capturedTextCodec :: Codec CapturedText
capturedTextCodec = Codec encode decode
  where
    encode (CapturedText contents (EvidenceFingerprint fingerprint)) = record
      [("contents",encodeWith textCodec contents),("fingerprint",encodeWith textCodec fingerprint)]
    decode value = do
      values <- fields ["contents","fingerprint"] value
      CapturedText <$> field "contents" textCodec values
        <*> (EvidenceFingerprint <$> field "fingerprint" textCodec values)

evidenceRequest :: Transport -> Codec payload -> Integer -> EvidenceRead payload a -> IO a
evidenceRequest transport _ identity (ListEvidenceIds (EvidenceSnapshot snapshot)) = exchange transport identity "evidence" "list"
  (record [("snapshot",encodeWith textCodec snapshot)]) (eitherCodec (listCodec identityCodec))
evidenceRequest transport payloadCodec identity (ReadEvidence (EvidenceSnapshot snapshot) key) = exchange transport identity "evidence" "read"
  (record [("snapshot",encodeWith textCodec snapshot),("id",encodeWith identityCodec key)])
  (eitherCodec (optionalCodec (evidenceCodec payloadCodec)))

exchange :: Transport -> Integer -> String -> String -> JSValue -> Codec a -> IO a
exchange transport identity capability method arguments codec = do
  (value,body) <- exchangeBody transport identity capability method arguments B.empty
  if B.null body then either fail pure (decodeWith codec value) else fail "Unexpected raw body"

exchangeBody :: Transport -> Integer -> String -> String -> JSValue -> B.ByteString -> IO (JSValue,B.ByteString)
exchangeBody transport identity capability method arguments body = do
  writeValueFrame transport (record [("tag",encodeWith stringCodec "HostRequest"),("id",encodeWith integerCodec identity),
    ("capability",encodeWith stringCodec capability),("method",encodeWith stringCodec method),("arguments",arguments)]) body
  (bytes,raw) <- readFrame transport
  either fail pure $ do
    values <- parseValue (T.unpack (TE.decodeUtf8 bytes)) >>= fields ["tag","id","result"]
    tag <- field "tag" stringCodec values
    actual <- field "id" integerCodec values
    if tag == "HostResponse" && actual == identity then (,) <$> field "result" (Codec id Right) values <*> pure raw
    else Left "Unexpected host response tag or request ID"

emit :: Transport -> JSValue -> IO ()
emit transport value = writeValueFrame transport value B.empty

identityCodec :: Codec EvidenceId
identityCodec = Codec (\(EvidenceId value) -> encodeWith textCodec value) (fmap EvidenceId . decodeWith textCodec)

eitherCodec :: Codec a -> Codec (Either FetchError a)
eitherCodec codec = Codec encode decode
  where
    encode (Left (FetchError message)) = tagged "Left" (Just (encodeWith textCodec message))
    encode (Right value) = tagged "Right" (Just (encodeWith codec value))
    decode value = do
      (tag,payload) <- variant value
      case (tag,payload) of
        ("Left",Just message) -> Left . FetchError <$> decodeWith textCodec message
        ("Right",Just result) -> Right <$> decodeWith codec result
        _ -> Left "Expected a typed Left or Right response"

evidenceCodec :: Codec a -> Codec (Evidence a)
evidenceCodec codec = Codec encode decode
  where
    encode (Evidence (EvidenceFingerprint fingerprint) references payload) = record
      [("fingerprint",encodeWith textCodec fingerprint),("externalReferences",encodeWith (listCodec textCodec) references),
      ("payload",encodeWith (payloadCodec codec) payload)]
    decode value = do
      values <- fields ["fingerprint","externalReferences","payload"] value
      Evidence <$> (EvidenceFingerprint <$> field "fingerprint" textCodec values)
        <*> field "externalReferences" (listCodec textCodec) values <*> field "payload" (payloadCodec codec) values

payloadCodec :: Codec a -> Codec (EvidencePayload a)
payloadCodec codec = Codec encode decode
  where
    encode (Available value) = tagged "Available" (Just (encodeWith codec value))
    encode Truncated = tagged "Truncated" Nothing
    decode value = do
      (tag,payload) <- variant value
      case (tag,payload) of
        ("Available",Just contents) -> Available <$> decodeWith codec contents
        ("Truncated",Nothing) -> Right Truncated
        _ -> Left "Expected Available or Truncated payload"

changeCodec :: Codec a -> Codec (EvidenceChange a)
changeCodec codec = Codec encode decode
  where
    encode (NewEvidence key evidence) = item "New" key evidence
    encode (UpdatedEvidence key evidence) = item "Updated" key evidence
    encode (RemovedEvidence key) = tagged "Removed" (Just (encodeWith identityCodec key))
    encode (SetEvidencePayload key (EvidenceFingerprint fingerprint) payload) = tagged "SetPayload" (Just (record
      [("id",encodeWith identityCodec key),("fingerprint",encodeWith textCodec fingerprint),
       ("payload",encodeWith (payloadCodec codec) payload)]))
    item tag key evidence = tagged tag (Just (record [("id",encodeWith identityCodec key),
      ("evidence",encodeWith (evidenceCodec codec) evidence)]))
    decode value = do
      (tag,payload) <- variant value
      case (tag,payload) of
        ("Removed",Just key) -> RemovedEvidence <$> decodeWith identityCodec key
        ("New",Just entry) -> entryValue NewEvidence entry
        ("Updated",Just entry) -> entryValue UpdatedEvidence entry
        ("SetPayload",Just entry) -> do
          values <- fields ["id","fingerprint","payload"] entry
          SetEvidencePayload <$> field "id" identityCodec values
            <*> (EvidenceFingerprint <$> field "fingerprint" textCodec values)
            <*> field "payload" (payloadCodec codec) values
        _ -> Left "Unknown evidence change"
    entryValue constructor value = do
      values <- fields ["id","evidence"] value
      constructor <$> field "id" identityCodec values <*> field "evidence" (evidenceCodec codec) values
