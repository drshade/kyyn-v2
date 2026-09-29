{-# LANGUAGE GADTs, TypeOperators, ScopedTypeVariables #-}
module Kyyn.Runtime.PluginHost (httpRequest, secretRequest, waitingRequest, loginRequest, executeAcquisition, executeLogin) where

import Kyyn.Runtime.Json
import Kyyn.Runtime.Plugin (exchange, execute, input, eitherCodec, changeCodec, fileRequest, evidenceRequest)
import Kyyn.Types.PluginHost
import Kyyn.Types.Plugin (EvidenceSnapshot, FileRead, EvidenceRead, FetchError)
import Kyyn.Types.Program
import Kyyn.Types.Evidence (EvidenceChange)

executeAcquisition :: forall config payload. Codec config -> Codec payload
  -> (config -> EvidenceSnapshot payload -> Program (Http :+: (Secrets :+: (Waiting :+: (FileRead :+: EvidenceRead payload))))
        (Either FetchError [EvidenceChange payload])) -> IO ()
executeAcquisition configCodec payloadCodec selected = do
  (config,snapshot) <- input configCodec
  execute (eitherCodec (listCodec (changeCodec payloadCodec))) handler (selected config snapshot)
  where
    handler :: Integer -> (Http :+: (Secrets :+: (Waiting :+: (FileRead :+: EvidenceRead payload)))) a -> IO a
    handler identity (InLeft call) = httpRequest identity call
    handler identity (InRight (InLeft call)) = secretRequest identity call
    handler identity (InRight (InRight (InLeft call))) = waitingRequest identity call
    handler identity (InRight (InRight (InRight (InLeft call)))) = fileRequest identity call
    handler identity (InRight (InRight (InRight (InRight call)))) = evidenceRequest payloadCodec identity call

executeLogin :: Codec config
  -> (config -> Program (Http :+: (Secrets :+: (Waiting :+: LoginInteraction))) (Either LoginError ())) -> IO ()
executeLogin configCodec selected = do
  line <- getLine
  config <- either fail pure (parseValue line >>= decodeWith configCodec)
  execute (resultCodec loginErrorCodec unitCodec) handler (selected config)
  where
    handler :: Integer -> (Http :+: (Secrets :+: (Waiting :+: LoginInteraction))) a -> IO a
    handler identity (InLeft call) = httpRequest identity call
    handler identity (InRight (InLeft call)) = secretRequest identity call
    handler identity (InRight (InRight (InLeft call))) = waitingRequest identity call
    handler identity (InRight (InRight (InRight call))) = loginRequest identity call
    loginErrorCodec = Codec (\(LoginError message) -> encodeWith stringCodec message)
      (fmap LoginError . decodeWith stringCodec)

httpRequest :: Integer -> Http a -> IO a
httpRequest identity (SendHttp (HttpRequest method url headers body)) = exchange identity "http" "send"
  (record [("method",encodeWith stringCodec method),("url",encodeWith stringCodec url),
    ("headers",encodeWith headersCodec headers),("body",encodeWith stringCodec body)])
  (resultCodec httpErrorCodec responseCodec)

secretRequest :: Integer -> Secrets a -> IO a
secretRequest identity (GetSecret key) = exchange identity "secrets" "get"
  (record [("key",encodeWith stringCodec key)]) (resultCodec secretErrorCodec stringCodec)
secretRequest identity (PutSecret key value) = exchange identity "secrets" "put"
  (record [("key",encodeWith stringCodec key),("value",encodeWith stringCodec value)]) unitCodec

waitingRequest :: Integer -> Waiting a -> IO a
waitingRequest identity (WaitSeconds seconds) = exchange identity "waiting" "seconds"
  (record [("seconds",encodeWith integerCodec (toInteger seconds))]) unitCodec

loginRequest :: Integer -> LoginInteraction a -> IO a
loginRequest identity (DisplayInstructions message) = exchange identity "login" "display"
  (record [("message",encodeWith stringCodec message)]) unitCodec

headersCodec :: Codec [(String,String)]
headersCodec = listCodec (Codec encode decode)
  where
    encode (name,value) = record [("name",encodeWith stringCodec name),("value",encodeWith stringCodec value)]
    decode value = do
      values <- fields ["name","value"] value
      (,) <$> field "name" stringCodec values <*> field "value" stringCodec values

responseCodec :: Codec HttpResponse
responseCodec = Codec encode decode
  where
    encode (HttpResponse status headers body) = record [("status",encodeWith integerCodec (toInteger status)),
      ("headers",encodeWith headersCodec headers),("body",encodeWith stringCodec body)]
    decode value = do
      values <- fields ["status","headers","body"] value
      status <- field "status" integerCodec values
      if status < 100 || status > 599 then Left "Invalid HTTP status" else
        HttpResponse (fromInteger status) <$> field "headers" headersCodec values <*> field "body" stringCodec values

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
secretErrorCodec = Codec (\(SecretNotFound key) -> tagged "SecretNotFound" (Just (encodeWith stringCodec key))) decode
  where
    decode value = do
      pair <- variant value
      case pair of
        ("SecretNotFound",Just key) -> SecretNotFound <$> decodeWith stringCodec key
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
