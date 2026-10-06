{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Auth (accessToken, login) where

import qualified Data.Text as Text
import Data.Text (Text)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Control.Monad.Trans.Class (lift)
import Kyyn.Plugin.Host
import MicrosoftGraph.Types (GraphAuth(..))
import qualified MicrosoftGraph.Json as Json
import qualified MicrosoftGraph.Http as Http
import Text.JSON.Types (JSValue)

endpoint :: Text -> Text -> Text
endpoint tenant operation = "https://login.microsoftonline.com/" <> Json.escape tenant <> "/oauth2/v2.0/" <> operation

accessToken :: GraphAuth -> Text -> NetworkHost rest (Either Text Text)
accessToken auth scope = runExceptT $ case auth of
  ClientSecret tenant client key -> do
    secret <- readKey key
    response <- ExceptT (Http.postForm (endpoint tenant "token")
      [("client_id",client),("client_secret",secret),("grant_type","client_credentials"),("scope","https://graph.microsoft.com/.default")])
    value <- either throwE pure (Http.requireSuccess response >>= Json.parse)
    either throwE pure (tokenField "access_token" value)
  DeviceCode tenant client key -> do
    refresh <- readKey key
    response <- ExceptT (Http.postForm (endpoint tenant "token")
      [("client_id",client),("refresh_token",refresh),("grant_type","refresh_token"),("scope",scope <> " offline_access")])
    let HttpResponse _ _ body = response
    case Json.parse body >>= Json.member "error" >>= Json.text of
      Right "invalid_grant" -> throwE "Refresh token was rejected; run connector login again."
      _ -> pure ()
    value <- either throwE pure (Http.requireSuccess response >>= Json.parse)
    token <- either throwE pure (tokenField "access_token" value)
    rotated <- either throwE pure (Json.optionalText "refresh_token" value)
    case rotated of Just "" -> throwE "Provider returned an empty refresh token"
                    Just next -> lift (putSecret key next)
                    Nothing -> pure ()
    pure token
  where
    readKey key = do
      value <- lift (getSecret key)
      either (const (throwE ("Missing secret " <> key <> "; configure it or run connector login."))) pure value

login :: GraphAuth -> Text -> PluginLogin (Either LoginError ())
login auth scope = fmap (either (Left . LoginError) Right) $ runExceptT $ case auth of
  ClientSecret {} -> ExceptT (fmap (fmap (const ())) (accessToken auth scope))
  DeviceCode tenant client key -> do
    response <- ExceptT (Http.postForm (endpoint tenant "devicecode") [("client_id",client),("scope",scope <> " offline_access")])
    value <- either throwE pure (Http.requireSuccess response >>= Json.parse)
    code <- either throwE pure (Json.member "device_code" value >>= Json.text)
    message <- either throwE pure (Json.member "message" value >>= Json.text)
    expires <- either throwE pure (Json.member "expires_in" value >>= Json.integer)
    interval <- either throwE pure (Json.optionalInteger "interval" 5 value)
    if expires <= 0 || interval <= 0 then throwE "Invalid device-code polling interval or expiry" else pure ()
    lift (displayInstructions message)
    poll tenant client key code expires interval
  where
    poll tenant client key code remaining interval
      | remaining < interval = throwE "Device login expired; run connector login again."
      | otherwise = do
          lift (waitSeconds interval)
          response@(HttpResponse status _ body) <- ExceptT (Http.postForm (endpoint tenant "token")
            [("grant_type","urn:ietf:params:oauth:grant-type:device_code"),("client_id",client),("device_code",code)])
          value <- either throwE pure (Json.parse body)
          if status >= 200 && status < 300 then do
            _ <- either throwE pure (tokenField "access_token" value)
            refresh <- either throwE pure (tokenField "refresh_token" value)
            lift (putSecret key refresh)
          else case Json.member "error" value >>= Json.text of
            Right "authorization_pending" -> poll tenant client key code (remaining - interval) interval
            Right "slow_down" | interval <= maxBound - 5 -> poll tenant client key code (remaining - interval) (interval + 5)
            Right "authorization_declined" -> throwE "Device login was declined."
            Right "expired_token" -> throwE "Device login expired; run connector login again."
            _ -> either throwE (const (throwE "Device login failed; run connector login again.")) (Http.requireSuccess response)

tokenField :: Text -> JSValue -> Either Text Text
tokenField key value = do
  token <- Json.member key value >>= Json.text
  if Text.null token then Left ("Provider returned an empty " <> key) else Right token
