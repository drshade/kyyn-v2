{-# LANGUAGE OverloadedStrings #-}
module Salesforce.Http (send, postForm, requireSuccess) where
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Plugin.Host
import qualified Salesforce.Json as Json

-- Bounded retries keep a failed query from waiting forever. No raw provider
-- body enters diagnostics: token responses can contain credentials.
send :: HttpRequest -> NetworkHost rest (Either Text HttpResponse)
send = attempt (3 :: Int)
  where
    attempt remaining request = do
      result <- sendHttp request
      case result of
        Left _ -> pure (Left "Salesforce HTTP transport failed")
        Right response@(HttpResponse status headers _)
          | status == 429 || status == 503 -> case delay headers of
              Just seconds | remaining > 0 -> waitSeconds seconds >> attempt (remaining-1) request
              _ -> pure (Left "Salesforce is throttled or unavailable; retry the fetch later")
          | otherwise -> pure (Right response)
    delay headers = lookup "retry-after" [(Text.toLower k,v) | (k,v) <- headers] >>= \s ->
      case reads (Text.unpack s) of
        [(n,"")] | n >= 0 && n <= 300 -> Just (max 1 n)
        _ -> Nothing

postForm :: Text -> [(Text,Text)] -> NetworkHost rest (Either Text HttpResponse)
postForm url fields = send (HttpRequest "POST" url [("Content-Type","application/x-www-form-urlencoded")] (Json.form fields))

requireSuccess :: HttpResponse -> Either Text Text
requireSuccess (HttpResponse status _ body)
  | status >= 200 && status < 300 = Right body
  | status == 401 = Left "Salesforce authentication rejected; run connector login again or check the configured credential"
  | status == 403 = Left "Salesforce access denied; check the app and user's API, object and field permissions"
  | otherwise = Left ("Salesforce returned HTTP " <> Text.pack (show status))
