{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Http (send, download, downloadOptional, postForm, requireSuccess) where

import qualified Data.Text as Text
import Data.Text (Text)
import Kyyn.Plugin.Host
import Kyyn.Plugin (FetchError(..))
import MicrosoftGraph.Json (form)

send :: HttpRequest -> NetworkHost rest (Either Text HttpResponse)
send request = do
  result <- sendHttp request
  case result of
    Left problem -> pure (Left ("HTTP transport failed: " <> Text.pack (show problem)))
    Right response@(HttpResponse status headers _)
      | status == 429 || status == 503 -> case retryAfter headers of
          Just delay -> waitSeconds delay >> send request
          Nothing -> pure (Left ("Provider returned HTTP " <> Text.pack (show status) <> "; retry later (no usable Retry-After)."))
      | otherwise -> pure (Right response)

-- The optional form preserves a typed 403 outcome for connectors that can skip
-- an inaccessible artifact. Existing callers still fail on every denied download.
download :: BlobDownload -> Acquisition payload (Either Text BlobRef)
download request = fmap (>>= maybe (Left "Attachment download returned HTTP 403") Right) (downloadOptional request)

downloadOptional :: BlobDownload -> Acquisition payload (Either Text (Maybe BlobRef))
downloadOptional request = do
  result <- storeBlob request
  case result of
    Left (FetchError problem) -> pure (Left problem)
    Right (BlobResponse status headers blob)
      | status == 429 || status == 503 -> case retryAfter headers of
          Just delay -> waitSeconds delay >> downloadOptional request
          Nothing -> pure (Left "Attachment throttled without usable Retry-After; retry later.")
      | status == 403 -> pure (Right Nothing)
      | status >= 200 && status < 300 -> pure (maybe (Left "Attachment download returned no content reference") (Right . Just) blob)
      | otherwise -> pure (Left ("Attachment download returned HTTP " <> Text.pack (show status)))

retryAfter :: [(Text,Text)] -> Maybe Int
retryAfter headers = lookup "retry-after" [(Text.toLower key,value) | (key,value) <- headers] >>= seconds
  where
    seconds value = case reads (Text.unpack value) of
      [(n,"")] | n >= 0 && n <= toInteger (maxBound :: Int) -> Just (max 1 (fromInteger n))
      _ -> Nothing

postForm :: Text -> [(Text,Text)] -> NetworkHost rest (Either Text HttpResponse)
postForm url fields = send (HttpRequest "POST" url [("Content-Type","application/x-www-form-urlencoded")] (form fields))

requireSuccess :: HttpResponse -> Either Text Text
requireSuccess (HttpResponse status _ body)
  | status >= 200 && status < 300 = Right body
  | status == 401 = Left "Authentication rejected; run connector login again or check the configured credential."
  | status == 403 = Left "Access denied; check application permissions, consent and mailbox sharing."
  | otherwise = Left ("Provider returned HTTP " <> Text.pack (show status))
