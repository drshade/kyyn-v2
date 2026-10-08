{-# LANGUAGE OverloadedStrings #-}
module GitHub.Http (get, pages, nextPage) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Plugin.Host
import qualified GitHub.Json as Json
import Text.JSON.Types (JSValue)

get :: Text -> Maybe Text -> Text -> Acquisition payload (Either Text (JSValue, Maybe Text))
get base token url
  | not (base `Text.isPrefixOf` url) = pure (Left "GitHub pagination left the selected repository")
  | otherwise = do
      result <- sendHttp (HttpRequest "GET" url
        ([("Accept","application/vnd.github+json"),("X-GitHub-Api-Version","2022-11-28"),("User-Agent","kyyn")]
         ++ maybe [] (\value -> [("Authorization","Bearer " <> value)]) token) "")
      pure $ case result of
        Left _ -> Left "GitHub HTTP transport failed"
        Right (HttpResponse status headers body)
          | status == 200 -> do
              value <- Json.parse body
              next <- nextPage headers
              pure (value,next)
          | status == 401 -> Left "GitHub rejected the token; check the configured KB secret"
          | status == 403 || status == 429 -> Left "GitHub refused or rate-limited the request; check token permissions and retry later"
          | status == 404 -> Left "GitHub resource unavailable; check the repository URL and token access (not treated as deletion)"
          | otherwise -> Left ("GitHub returned HTTP " <> Text.pack (show status))

nextPage :: [(Text,Text)] -> Either Text (Maybe Text)
nextPage headers = case [part | (name,value) <- headers, Text.toLower name == "link",
    part <- Text.splitOn "," value, any ((== "rel=\"next\"") . Text.strip) (drop 1 (Text.splitOn ";" part))] of
  [] -> Right Nothing
  [part] -> case Text.splitOn ";" part of
    first:_ -> case Text.stripPrefix "<" (Text.strip first) >>= Text.stripSuffix ">" of
      Just url | not (Text.null url) -> Right (Just url)
      _ -> Left "Malformed GitHub next-page link"
    _ -> Left "Malformed GitHub pagination"
  _ -> Left "Multiple GitHub next-page links"

pages :: Text -> Maybe Text -> Text -> Acquisition payload (Either Text [JSValue])
pages base token = runExceptT . go []
  where
    go seen url
      | url `elem` seen = throwE "GitHub pagination repeated a page"
      | otherwise = do
          (value,next) <- ExceptT (get base token url)
          items <- either throwE pure (Json.array value)
          rest <- maybe (pure []) (go (url:seen)) next
          pure (items ++ rest)
