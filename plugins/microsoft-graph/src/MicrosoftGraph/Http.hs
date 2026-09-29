module MicrosoftGraph.Http (send, postForm, requireSuccess) where

import Data.Char (toLower)
import Kyyn.Plugin.Host
import MicrosoftGraph.Json (form)

send :: HttpRequest -> NetworkHost rest (Either String HttpResponse)
send request = do
  result <- sendHttp request
  case result of
    Left problem -> pure (Left ("HTTP transport failed: " ++ show problem))
    Right response@(HttpResponse status headers _)
      | status == 429 || status == 503 -> case lookup "retry-after" [(map toLower key,value) | (key,value) <- headers] >>= seconds of
          Just delay -> waitSeconds delay >> send request
          Nothing -> pure (Left ("Provider returned HTTP " ++ show status ++ "; retry later (no usable Retry-After)."))
      | otherwise -> pure (Right response)
  where
    seconds value = case reads value of
      [(n,"")] | n >= 0 && n <= toInteger (maxBound :: Int) -> Just (max 1 (fromInteger n))
      _ -> Nothing

postForm :: String -> [(String,String)] -> NetworkHost rest (Either String HttpResponse)
postForm url fields = send (HttpRequest "POST" url [("Content-Type","application/x-www-form-urlencoded")] (form fields))

requireSuccess :: HttpResponse -> Either String String
requireSuccess (HttpResponse status _ body)
  | status >= 200 && status < 300 = Right body
  | status == 401 = Left "Authentication rejected; run connector login again or check the configured credential."
  | status == 403 = Left "Access denied; check application permissions, consent and mailbox sharing."
  | otherwise = Left ("Provider returned HTTP " ++ show status)
