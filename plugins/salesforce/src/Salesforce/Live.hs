module Salesforce.Live (query, decodeResponse) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Data.Bifunctor (first)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.ByteString as Bytes
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as Keys
import Kyyn.Plugin (FetchError(..))
import Kyyn.Plugin.Live (LiveQueryProgram)
import Kyyn.Plugin.Host (HttpRequest(..), HttpResponse(..))
import Salesforce.Live.Types
import qualified Salesforce.Auth as Auth
import qualified Salesforce.Http as Http
import qualified Salesforce.Json as Json

query :: LiveConfig -> Soql -> LiveQueryProgram (Either FetchError QueryResult)
query (LiveConfig origin auth version) (Soql soql) = fmap (first FetchError) $ runExceptT $ do
  token <- ExceptT (Auth.accessToken origin auth)
  response <- ExceptT (Http.send (HttpRequest "GET"
    (origin <> "/services/data/" <> version <> "/query?q=" <> Json.escape soql)
    [("Authorization","Bearer " <> token),("Accept","application/json")] ""))
  ExceptT (pure (decodeResponse response))

-- One provider page; callers can narrow their query when the explicit bound is hit.
-- No record identity is required, so aggregate SOQL results work too.
decodeResponse :: HttpResponse -> Either Text QueryResult
decodeResponse response@(HttpResponse status _ body)
  | status == 400 = do
      errors <- Json.parse body >>= Json.array
      case errors of
        [problem] -> do
          code <- Json.member "errorCode" problem >>= Json.text
          message <- Json.member "message" problem >>= Json.text
          if code `elem` ["MALFORMED_QUERY","INVALID_FIELD","INVALID_TYPE"]
            then Right (Rejected code (Text.take 2000 message))
            else Left ("Salesforce rejected the request: " <> Text.take 100 code)
        _ -> Left "Unexpected Salesforce query error response"
  | otherwise = do
      value <- Http.requireSuccess response >>= Json.parse
      total <- Json.member "totalSize" value >>= Json.integer
      done <- Json.member "done" value >>= Json.boolean
      records <- Json.member "records" value >>= Json.array
      -- COUNT() carries its answer in totalSize, with no record rows.
      if length records > total || (done && not (null records) && length records /= total)
        then Left "Salesforce query record count differs from totalSize" else pure ()
      let selected = bounded 100 32768 records
      rows <- traverse row selected
      pure (Records rows total (not done || length selected < length records || any incomplete selected))
  where
    bounded :: Int -> Int -> [Aeson.Value] -> [Aeson.Value]
    bounded _ _ [] = []
    bounded count bytes (value:rest)
      | count <= 0 || size > bytes = []
      | otherwise = value : bounded (count-1) (bytes-size) rest
      where size = Bytes.length (Text.encodeUtf8 (Json.canonical value))
    row (Aeson.Object fields) = Right (Row
      [Field (Key.toText name) (field value) | (name,value) <- Keys.toAscList fields, name /= "attributes"])
    row _ = Left "SOQL records must be JSON objects"
    field Aeson.Null = Null
    field (Aeson.Bool value) = Boolean value
    field value@(Aeson.Number _) = Number (Json.canonical value)
    field (Aeson.String value) = TextValue value
    field value = JsonValue (Json.canonical value)
    incomplete (Aeson.Object fields) =
      (Keys.member "records" fields && Keys.lookup "done" fields == Just (Aeson.Bool False)) || any incomplete fields
    incomplete (Aeson.Array values) = any incomplete values
    incomplete _ = False
