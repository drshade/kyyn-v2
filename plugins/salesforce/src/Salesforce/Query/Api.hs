{-# LANGUAGE OverloadedStrings #-}
module Salesforce.Query.Api (records) where
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (group, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Text.JSON.Types (JSValue(..), fromJSObject)
import Kyyn.Plugin.Host
import Salesforce.Query.Types
import qualified Salesforce.Http as Http
import qualified Salesforce.Json as Json

records :: Text -> QueryConfig -> Acquisition Record (Either Text [(Text,Record)])
records token (QueryConfig origin _ version query field) = runExceptT $ do
  values <- pages [] Nothing (path <> "?q=" <> Json.escape query)
  rows <- either throwE pure (mapM row values)
  let keys = map fst rows
  if length keys /= length (group (sort keys)) then throwE "SOQL result contains duplicate identities; select a unique idField" else pure rows
  where
    path = "/services/data/" <> version <> "/query"
    pages seen expected relative
      | relative `elem` seen = throwE "Salesforce repeated a query page"
      | otherwise = do
          response <- ExceptT (Http.send (HttpRequest "GET" (origin <> relative)
            [("Authorization","Bearer " <> token),("Accept","application/json")] ""))
          value <- either throwE pure (Http.requireSuccess response >>= Json.parse)
          -- Reject ambiguous object keys before interpreting control fields.
          _ <- either throwE pure (Json.canonical value)
          total <- either throwE pure (Json.member "totalSize" value >>= Json.integer)
          done <- either throwE pure (Json.member "done" value >>= Json.boolean)
          batch <- either throwE pure (Json.member "records" value >>= Json.array)
          next <- either throwE pure (Json.optionalText "nextRecordsUrl" value)
          case expected of
            Just size | size /= total -> throwE "Salesforce query totalSize changed across pages"
            _ -> pure ()
          rest <- if done then
              case next of Nothing -> pure []; Just _ -> throwE "Completed Salesforce query has a continuation"
            else case next of
              Just link | validNext link && not (null batch) -> pages (relative:seen) (Just total) link
              _ -> throwE "Incomplete Salesforce query has no valid continuation"
          let combined = batch ++ rest
          if null seen && length combined /= total then throwE "Salesforce query record count differs from totalSize" else pure combined
    validNext link = case Text.stripPrefix (path <> "/") link of
      Just suffix -> not (Text.null suffix) && Text.all (\c -> c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c `elem` ("-_" :: String)) suffix
      Nothing -> False
    row value@(JSObject _) = do
      key <- Json.member field value >>= Json.text
      if Text.null (Text.strip key) then Left "SOQL record has a blank identity" else pure ()
      completeRelationships value
      body <- Json.canonical value
      pure (key,Record key body)
    row _ = Left "SOQL records must be JSON objects"

-- A nested query can have its own continuation. Do not publish a partial child
-- collection as a complete record; query that child object separately instead.
completeRelationships :: JSValue -> Either Text ()
completeRelationships (JSObject object) = do
  let fields = fromJSObject object
  case (lookup "records" fields,lookup "done" fields) of
    (Just (JSArray _),Just (JSBool False)) -> Left "Nested relationship result is paginated; query the child object separately"
    _ -> pure ()
  mapM_ (completeRelationships . snd) fields
completeRelationships (JSArray values) = mapM_ completeRelationships values
completeRelationships _ = Right ()
