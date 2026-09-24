{-# LANGUAGE DataKinds, GADTs, OverloadedStrings #-}
module Kyyn.Plumbing.Interpreter.Judgement (runJudgementIO, runJudgementWithTransport) where

import Control.Exception (try)
import Data.Aeson (encode, eitherDecode)
import qualified Data.ByteString.Lazy as Bytes
import qualified Data.Text.Encoding as Text
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Secret (secretName)
import Kyyn.Plumbing.Capability.Judgement
import Kyyn.Plumbing.Capability.Judgement.Jev (requestBody, decodeResponse)
import Kyyn.Plumbing.Capability.SecretStore (SecretStore, readSecret)
import Kyyn.Types.Judgement
import qualified Network.HTTP.Client as Http
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)

runJudgementIO :: (IOE :> es, SecretStore :> es) => Eff (Judgement : es) a -> Eff es a
runJudgementIO action = do
  manager <- liftIO (Http.newManager tlsManagerSettings { Http.managerRetryableException = const False })
  runJudgementWithTransport (\request -> do
    response <- Http.httpLbs request manager
    pure (statusCode (Http.responseStatus response), Http.responseBody response)) action

runJudgementWithTransport :: (IOE :> es, SecretStore :> es)
  => (Http.Request -> IO (Int, Bytes.ByteString)) -> Eff (Judgement : es) a -> Eff es a
runJudgementWithTransport transport = interpret $ \_ (Judge question) -> case validateQuestion question of
  Left failure -> pure (Left failure)
  Right () -> do
    credential <- readSecret (either error id (secretName "JEV_TOKEN"))
    case credential of
      Left _ -> pure (Left (MissingSecret "JEV_TOKEN; use kyyn-v2 --kb PATH secret set JEV_TOKEN"))
      Right key -> do
        let request = Http.defaultRequest
              { Http.host = "api.typesafe.ai", Http.port = 443, Http.secure = True
              , Http.path = "/v1/systemone", Http.method = "POST"
              , Http.requestHeaders = [("Authorization", "Bearer " <> Text.encodeUtf8 key), ("Content-Type", "application/json")]
              , Http.requestBody = Http.RequestBodyLBS (encode (requestBody question))
              , Http.responseTimeout = Http.responseTimeoutMicro 30000000
              , Http.redirectCount = 0, Http.checkResponse = \_ _ -> pure () }
        response <- liftIO (try @Http.HttpException (transport request))
        pure $ case response of
          Left _ -> Left ProviderUnavailable
          Right (status,bytes)
            | status == 200 -> case eitherDecode bytes of
                Left _ -> Left InvalidProviderResponse
                Right value -> decodeResponse question value
            | status == 401 || status == 403 -> Left AuthenticationRejected
            | status == 429 -> Left RateLimited
            | status >= 500 -> Left ProviderUnavailable
            | otherwise -> Left RequestRejected
