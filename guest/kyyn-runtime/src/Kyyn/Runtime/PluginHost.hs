{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs, TypeOperators, ScopedTypeVariables #-}
module Kyyn.Runtime.PluginHost (httpRequest, secretRequest, waitingRequest, loginRequest, executeAcquisition, executeAcquisitionResult, executeLogin) where

import Kyyn.Runtime.Json
import Kyyn.Runtime.Plugin (exchange, exchangeBody, execute, input, eitherCodec, changeCodec, fileRequest, evidenceRequest, blobCodec)
import Kyyn.Runtime.Transport
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Kyyn.Types.PluginHost
import Kyyn.Types.Blob
import Kyyn.Types.Plugin (EvidenceSnapshot, FileRead, EvidenceRead, FetchError)
import Kyyn.Types.Program
import Kyyn.Types.Evidence (EvidenceChange)

executeAcquisition :: forall config payload. Codec config -> Codec payload
  -> (config -> EvidenceSnapshot payload -> Program (Http :+: (Secrets :+: (Waiting :+: (FileRead :+: (BlobAcquisition :+: (ContentDigest :+: EvidenceRead payload))))))
        (Either FetchError [EvidenceChange payload])) -> IO ()
executeAcquisition configCodec payloadCodec = executeAcquisitionResult configCodec payloadCodec (listCodec (changeCodec payloadCodec))

executeAcquisitionResult :: forall config payload result. Codec config -> Codec payload -> Codec result
  -> (config -> EvidenceSnapshot payload -> Program (Http :+: (Secrets :+: (Waiting :+: (FileRead :+: (BlobAcquisition :+: (ContentDigest :+: EvidenceRead payload))))))
        (Either FetchError result)) -> IO ()
executeAcquisitionResult configCodec payloadCodec resultCodec selected = withTransport $ \transport -> do
  (config,snapshot) <- input transport configCodec
  execute transport (eitherCodec resultCodec) (handler transport) (selected config snapshot)
  where
    handler :: Transport -> Integer -> (Http :+: (Secrets :+: (Waiting :+: (FileRead :+: (BlobAcquisition :+: (ContentDigest :+: EvidenceRead payload)))))) a -> IO a
    handler transport identity (InLeft call) = httpRequest transport identity call
    handler transport identity (InRight (InLeft call)) = secretRequest transport identity call
    handler transport identity (InRight (InRight (InLeft call))) = waitingRequest transport identity call
    handler transport identity (InRight (InRight (InRight (InLeft call)))) = fileRequest transport identity call
    handler transport identity (InRight (InRight (InRight (InRight (InLeft (StoreBlob (BlobDownload (HttpRequest method url headers body) name media))))))) = do
      (reply,raw) <- exchangeBody transport identity "blobs" "store" (record
        [("method",encodeWith textCodec method),("url",encodeWith textCodec url),
         ("headers",encodeWith headersCodec headers),("name",encodeWith (optionalCodec textCodec) name),
         ("mediaType",encodeWith (optionalCodec textCodec) media)]) (TE.encodeUtf8 body)
      if B.null raw then either fail pure (decodeWith (eitherCodec blobResponseCodec) reply)
        else fail "Raw body accompanies blob download metadata"
    handler transport identity (InRight (InRight (InRight (InRight (InRight (InLeft (DigestText values))))))) =
      exchange transport identity "digest" "text" (encodeWith (listCodec textCodec) values) (listCodec textCodec)
    handler transport identity (InRight (InRight (InRight (InRight (InRight (InRight call)))))) = evidenceRequest transport payloadCodec identity call

blobResponseCodec :: Codec BlobResponse
blobResponseCodec = Codec encode decode
  where
    encode (BlobResponse status headers blob) = record
      [("status",encodeWith integerCodec (toInteger status)),("headers",encodeWith headersCodec headers),
       ("blob",encodeWith (optionalCodec blobCodec) blob)]
    decode value = do
      values <- fields ["status","headers","blob"] value
      status <- field "status" integerCodec values
      if status < 100 || status > 599 then Left "Invalid blob HTTP status" else
        BlobResponse (fromInteger status) <$> field "headers" headersCodec values
          <*> field "blob" (optionalCodec blobCodec) values

executeLogin :: Codec config
  -> (config -> Program (Http :+: (Secrets :+: (Waiting :+: LoginInteraction))) (Either LoginError ())) -> IO ()
executeLogin configCodec selected = withTransport $ \transport -> do
  line <- readJson transport
  config <- either fail pure (parseValue line >>= decodeWith configCodec)
  execute transport (resultCodec loginErrorCodec unitCodec) (handler transport) (selected config)
  where
    handler :: Transport -> Integer -> (Http :+: (Secrets :+: (Waiting :+: LoginInteraction))) a -> IO a
    handler transport identity (InLeft call) = httpRequest transport identity call
    handler transport identity (InRight (InLeft call)) = secretRequest transport identity call
    handler transport identity (InRight (InRight (InLeft call))) = waitingRequest transport identity call
    handler transport identity (InRight (InRight (InRight call))) = loginRequest transport identity call
    loginErrorCodec = Codec (\(LoginError message) -> encodeWith textCodec message)
      (fmap LoginError . decodeWith textCodec)

httpRequest :: Transport -> Integer -> Http a -> IO a
httpRequest transport identity (SendHttp (HttpRequest method url headers body)) = do
  (value,raw) <- exchangeBody transport identity "http" "send"
    (record [("method",encodeWith textCodec method),("url",encodeWith textCodec url),
      ("headers",encodeWith headersCodec headers)]) (TE.encodeUtf8 body)
  result <- either fail pure (decodeWith (resultCodec httpErrorCodec (responseCodec raw)) value)
  case result of
    Left _ | not (B.null raw) -> fail "Raw body accompanies failed HTTP request"
    _ -> pure result

secretRequest :: Transport -> Integer -> Secrets a -> IO a
secretRequest transport identity (GetSecret key) = exchange transport identity "secrets" "get"
  (record [("key",encodeWith textCodec key)]) (resultCodec secretErrorCodec textCodec)
secretRequest transport identity (PutSecret key value) = exchange transport identity "secrets" "put"
  (record [("key",encodeWith textCodec key),("value",encodeWith textCodec value)]) unitCodec

waitingRequest :: Transport -> Integer -> Waiting a -> IO a
waitingRequest transport identity (WaitSeconds seconds) = exchange transport identity "waiting" "seconds"
  (record [("seconds",encodeWith integerCodec (toInteger seconds))]) unitCodec

loginRequest :: Transport -> Integer -> LoginInteraction a -> IO a
loginRequest transport identity (DisplayInstructions message) = exchange transport identity "login" "display"
  (record [("message",encodeWith textCodec message)]) unitCodec

headersCodec :: Codec [(T.Text,T.Text)]
headersCodec = listCodec (Codec encode decode)
  where
    encode (name,value) = record [("name",encodeWith textCodec name),("value",encodeWith textCodec value)]
    decode value = do
      values <- fields ["name","value"] value
      (,) <$> field "name" textCodec values <*> field "value" textCodec values

responseCodec :: B.ByteString -> Codec HttpResponse
responseCodec raw = Codec encode decode
  where
    encode (HttpResponse status headers _) = record [("status",encodeWith integerCodec (toInteger status)),
      ("headers",encodeWith headersCodec headers)]
    decode value = do
      values <- fields ["status","headers"] value
      status <- field "status" integerCodec values
      if status < 100 || status > 599 then Left "Invalid HTTP status" else
        HttpResponse (fromInteger status) <$> field "headers" headersCodec values <*> pure (TE.decodeUtf8 raw)

httpErrorCodec :: Codec HttpError
httpErrorCodec = Codec encode decode
  where
    encode value = tagged (show value) Nothing
    decode value = do
      pair <- variant value
      case pair of
        ("InvalidHttpRequest",Nothing) -> Right InvalidHttpRequest
        ("HttpTimedOut",Nothing) -> Right HttpTimedOut
        ("HttpConnectionFailed",Nothing) -> Right HttpConnectionFailed
        ("HttpUnavailable",Nothing) -> Right HttpUnavailable
        ("InvalidHttpResponse",Nothing) -> Right InvalidHttpResponse
        _ -> Left "Unknown HTTP error"

secretErrorCodec :: Codec SecretError
secretErrorCodec = Codec (\(SecretNotFound key) -> tagged "SecretNotFound" (Just (encodeWith textCodec key))) decode
  where
    decode value = do
      pair <- variant value
      case pair of
        ("SecretNotFound",Just key) -> SecretNotFound <$> decodeWith textCodec key
        _ -> Left "Unknown secret error"

unitCodec :: Codec ()
unitCodec = Codec (const (record [])) (\value -> fields [] value >> Right ())

resultCodec :: Codec e -> Codec a -> Codec (Either e a)
resultCodec errorCodec valueCodec = Codec encode decode
  where
    encode (Left problem) = tagged "Left" (Just (encodeWith errorCodec problem))
    encode (Right value) = tagged "Right" (Just (encodeWith valueCodec value))
    decode value = do
      pair <- variant value
      case pair of
        ("Left",Just problem) -> Left <$> decodeWith errorCodec problem
        ("Right",Just result) -> Right <$> decodeWith valueCodec result
        _ -> Left "Expected Left or Right"
