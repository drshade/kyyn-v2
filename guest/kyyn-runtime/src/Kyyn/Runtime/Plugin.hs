{-# LANGUAGE GADTs, TypeOperators, RankNTypes, ScopedTypeVariables #-}
module Kyyn.Runtime.Plugin (executeCapturedRead, execute, exchange, exchangeBody, eitherCodec, withOptionsCodec, input, fileRequest, evidenceRequest, changeCodec) where

import Kyyn.Runtime.Json
import Kyyn.Types.Evidence (EvidenceId(..), EvidenceFingerprint(..), Evidence(..), EvidenceChange(..))
import Kyyn.Types.Plugin
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

executeCapturedRead :: Codec arguments -> Codec payload -> Codec result
  -> (arguments -> EvidenceSnapshot payload -> Program (EvidenceRead payload) (Either FetchError result)) -> IO ()
executeCapturedRead argumentCodec payloadCodec resultCodec selected = withTransport $ \transport -> do
  (arguments, snapshot) <- input transport argumentCodec
  execute transport (eitherCodec resultCodec) (evidenceRequest transport payloadCodec) (selected arguments snapshot)

input :: Transport -> Codec a -> IO (a, EvidenceSnapshot payload)
input transport codec = do
  line <- readJson transport
  either fail pure $ do
    values <- parseValue line >>= fields ["arguments","snapshot"]
    arguments <- field "arguments" codec values
    snapshot <- EvidenceSnapshot <$> field "snapshot" stringCodec values
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
      [("contents",encodeWith stringCodec contents),("fingerprint",encodeWith stringCodec fingerprint)]
    decode value = do
      values <- fields ["contents","fingerprint"] value
      CapturedText <$> field "contents" stringCodec values
        <*> (EvidenceFingerprint <$> field "fingerprint" stringCodec values)

evidenceRequest :: Transport -> Codec payload -> Integer -> EvidenceRead payload a -> IO a
evidenceRequest transport _ identity (ListEvidenceIds (EvidenceSnapshot snapshot)) = exchange transport identity "evidence" "list"
  (record [("snapshot",encodeWith stringCodec snapshot)]) (eitherCodec (listCodec identityCodec))
evidenceRequest transport payloadCodec identity (ReadEvidence (EvidenceSnapshot snapshot) key) = exchange transport identity "evidence" "read"
  (record [("snapshot",encodeWith stringCodec snapshot),("id",encodeWith identityCodec key)])
  (eitherCodec (optionalCodec (evidenceCodec payloadCodec)))

exchange :: Transport -> Integer -> String -> String -> JSValue -> Codec a -> IO a
exchange transport identity capability method arguments codec = do
  (value,body) <- exchangeBody transport identity capability method arguments B.empty
  if B.null body then either fail pure (decodeWith codec value) else fail "Unexpected raw body"

exchangeBody :: Transport -> Integer -> String -> String -> JSValue -> B.ByteString -> IO (JSValue,B.ByteString)
exchangeBody transport identity capability method arguments body = do
  encoded <- either fail pure (printValue (record [("tag",encodeWith stringCodec "HostRequest"),("id",encodeWith integerCodec identity),
    ("capability",encodeWith stringCodec capability),("method",encodeWith stringCodec method),("arguments",arguments)]))
  writeFrame transport [TE.encodeUtf8 (T.pack encoded)] body
  (bytes,raw) <- readFrame transport
  either fail pure $ do
    values <- parseValue (T.unpack (TE.decodeUtf8 bytes)) >>= fields ["tag","id","result"]
    tag <- field "tag" stringCodec values
    actual <- field "id" integerCodec values
    if tag == "HostResponse" && actual == identity then (,) <$> field "result" (Codec id Right) values <*> pure raw
    else Left "Unexpected host response tag or request ID"

emit :: Transport -> JSValue -> IO ()
emit transport value = either fail (writeJson transport) (printValue value)

identityCodec :: Codec EvidenceId
identityCodec = Codec (\(EvidenceId value) -> encodeWith stringCodec value) (fmap EvidenceId . decodeWith stringCodec)

eitherCodec :: Codec a -> Codec (Either FetchError a)
eitherCodec codec = Codec encode decode
  where
    encode (Left (FetchError message)) = tagged "Left" (Just (encodeWith stringCodec message))
    encode (Right value) = tagged "Right" (Just (encodeWith codec value))
    decode value = do
      (tag,payload) <- variant value
      case (tag,payload) of
        ("Left",Just message) -> Left . FetchError <$> decodeWith stringCodec message
        ("Right",Just result) -> Right <$> decodeWith codec result
        _ -> Left "Expected a typed Left or Right response"

evidenceCodec :: Codec a -> Codec (Evidence a)
evidenceCodec codec = Codec encode decode
  where
    encode (Evidence (EvidenceFingerprint fingerprint) references payload) = record
      [("fingerprint",encodeWith stringCodec fingerprint),("references",encodeWith (listCodec stringCodec) references),
      ("payload",encodeWith codec payload)]
    decode value = do
      values <- fields ["fingerprint","references","payload"] value
      Evidence <$> (EvidenceFingerprint <$> field "fingerprint" stringCodec values)
        <*> field "references" (listCodec stringCodec) values <*> field "payload" codec values

changeCodec :: Codec a -> Codec (EvidenceChange a)
changeCodec codec = Codec encode decode
  where
    encode (NewEvidence key evidence) = item "New" key evidence
    encode (UpdatedEvidence key evidence) = item "Updated" key evidence
    encode (RemovedEvidence key) = tagged "Removed" (Just (encodeWith identityCodec key))
    item tag key evidence = tagged tag (Just (record [("id",encodeWith identityCodec key),
      ("evidence",encodeWith (evidenceCodec codec) evidence)]))
    decode value = do
      (tag,payload) <- variant value
      case (tag,payload) of
        ("Removed",Just key) -> RemovedEvidence <$> decodeWith identityCodec key
        ("New",Just entry) -> entryValue NewEvidence entry
        ("Updated",Just entry) -> entryValue UpdatedEvidence entry
        _ -> Left "Unknown evidence change"
    entryValue constructor value = do
      values <- fields ["id","evidence"] value
      constructor <$> field "id" identityCodec values <*> field "evidence" (evidenceCodec codec) values
