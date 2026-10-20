{-# LANGUAGE OverloadedStrings #-}
module Salesforce.Auth (accessToken, login) where
import Data.Text (Text)
import qualified Data.Text as Text
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Control.Monad.Trans.Class (lift)
import Kyyn.Plugin.Host
import Salesforce.Types
import Salesforce.Config (tokenEndpoint)
import qualified Salesforce.Json as Json
import qualified Salesforce.Http as Http
import Text.JSON.Types (JSValue)

accessToken :: Text -> SalesforceAuth -> NetworkHost rest (Either Text Text)
accessToken origin auth = runExceptT $ do
  let (client,key) = case auth of ClientSecret c k -> (c,k); DeviceCode c k -> (c,k)
  stored <- lift (getSecret key)
  secret <- either (const (throwE ("Missing secret " <> key <> "; configure it or run connector login"))) pure stored
  if Text.null secret then throwE "Salesforce credential is empty" else pure ()
  let fields = case auth of
        ClientSecret {} -> [("grant_type","client_credentials"),("client_id",client),("client_secret",secret)]
        DeviceCode {} -> [("grant_type","refresh_token"),("client_id",client),("refresh_token",secret)]
  response <- ExceptT (Http.postForm (tokenEndpoint origin) fields)
  case (auth,response) of
    (DeviceCode {},HttpResponse 400 _ body)
      | (Json.parse body >>= Json.member "error" >>= Json.text) == Right "invalid_grant" ->
          throwE "Salesforce refresh token was rejected; run connector login again"
    _ -> pure ()
  value <- either throwE pure (Http.requireSuccess response >>= Json.parse)
  token <- either throwE pure (required "access_token" value)
  case auth of
    ClientSecret {} -> pure ()
    DeviceCode {} -> do
      rotated <- either throwE pure (Json.optionalText "refresh_token" value)
      case rotated of
        Just "" -> throwE "Salesforce returned an empty refresh token"
        Just next -> lift (putSecret key next)
        Nothing -> pure ()
  pure token

login :: Text -> SalesforceAuth -> PluginLogin (Either LoginError ())
login origin auth = fmap (either (Left . LoginError) Right) $ runExceptT $ case auth of
  ClientSecret {} -> ExceptT (fmap (fmap (const ())) (accessToken origin auth))
  DeviceCode client key -> do
    response <- ExceptT (Http.postForm endpoint [("response_type","device_code"),("client_id",client),("scope","api refresh_token")])
    value <- either throwE pure (Http.requireSuccess response >>= Json.parse)
    code <- either throwE pure (required "device_code" value)
    uri <- either throwE pure (required "verification_uri" value)
    userCode <- either throwE pure (required "user_code" value)
    expires <- either throwE pure (Json.optionalInteger "expires_in" 600 value)
    interval <- either throwE pure (Json.optionalInteger "interval" 5 value)
    if expires <= 0 || interval <= 0 then throwE "Invalid device login polling interval or expiry" else pure ()
    lift (displayInstructions ("Open " <> uri <> " and enter code " <> userCode))
    poll client key code expires interval
  where
    endpoint = tokenEndpoint origin
    poll client key code remaining interval
      | remaining < interval = throwE "Salesforce device login expired; run login again"
      | otherwise = do
          lift (waitSeconds interval)
          response@(HttpResponse status _ body) <- ExceptT (Http.postForm endpoint
            [("grant_type","device"),("client_id",client),("code",code)])
          if status >= 200 && status < 300 then do
            value <- either throwE pure (Json.parse body)
            _ <- either throwE pure (required "access_token" value)
            refresh <- either throwE pure (required "refresh_token" value)
            lift (putSecret key refresh)
          else if status /= 400 then
            either throwE (const (throwE "Salesforce device login failed")) (Http.requireSuccess response)
          else case Json.parse body >>= Json.member "error" >>= Json.text of
            Right "authorization_pending" -> poll client key code (remaining-interval) interval
            Right "slow_down" | interval <= maxBound-5 -> poll client key code (remaining-interval) (interval+5)
            Right "access_denied" -> throwE "Salesforce device login was declined"
            Right "expired_token" -> throwE "Salesforce device login expired; run login again"
            _ -> either throwE (const (throwE "Salesforce device login failed")) (Http.requireSuccess response)

required :: Text -> JSValue -> Either Text Text
required key value = do
  result <- Json.member key value >>= Json.text
  if Text.null result then Left ("Salesforce returned an empty " <> key) else Right result
