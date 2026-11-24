module MicrosoftGraph.Teams.Api (send, messagesUrl, checkedPage, field, nonempty, encode, reply, ordinaryReply) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Aeson as Aeson
import Data.List (nub)
import qualified Network.HTTP.Client as Client
import Network.HTTP.Types.URI (urlDecode)
import Kyyn.Plugin.Event (LiveEvent)
import Kyyn.Plugin.Host
import MicrosoftGraph.Config (graphApiBase)
import MicrosoftGraph.Teams.Types
import MicrosoftGraph.Timestamp (timestamp)
import qualified MicrosoftGraph.Json as Json
import qualified MicrosoftGraph.Http as Http

-- Leave retries to the host's paced polls. In particular, do not sleep through
-- a long Retry-After and obscure the provider's explanation with a deadline.
send :: HttpRequest -> LiveEvent (Either Text Aeson.Value)
send request@(HttpRequest method _ _ _) = do
  result <- sendHttp request
  pure $ case result of
    Left problem -> Left ("Teams HTTP transport failed: " <> Text.pack (show problem))
    Right response@(HttpResponse status headers _) ->
      if status == 429 || status == 503 then
        Left ("Teams returned HTTP " <> Text.pack (show status) <> "; Retry-After: " <>
          maybe "not supplied" safeDelay (lookup "retry-after" [(Text.toLower key,value) | (key,value) <- headers]))
      else do
        body <- Http.requireSuccess response
        if status == (if method == "POST" then 201 else 200)
          then Json.parse body else Left "Unexpected Teams success status."
  where
    safeDelay value | Text.length value <= 80 && Text.all (\c -> c >= ' ' && c <= '~') value = value
                    | otherwise = "invalid header"

messagesUrl :: TeamsConfig -> Text
messagesUrl (TeamsConfig _ chat _) = graphApiBase <> "chats/" <> Json.escape chat <> "/messages"

checkedPage :: TeamsConfig -> Text -> Either Text Text
checkedPage (TeamsConfig _ chat _) url = case Client.parseRequest (Text.unpack url) :: Maybe Client.Request of
  Just request
    | Client.secure request && Client.port request == 443
    , Text.toLower (Encoding.decodeUtf8 (Client.host request)) == "graph.microsoft.com"
    , null (Client.requestHeaders request)
    , not (Text.any (`elem` ['#','\r','\n']) url)
    , Right path <- Encoding.decodeUtf8' (urlDecode False (Client.path request))
    , path == "/v1.0/chats/" <> chat <> "/messages" -> Right url
  _ -> Left "Unexpected Teams pagination URL."

field :: Text -> Aeson.Value -> Either Text Text
field key value = Json.member key value >>= Json.text

nonempty :: Text -> Aeson.Value -> Either Text Text
nonempty key value = do
  result <- field key value
  if Text.null result then Left ("Empty Teams response field: " <> key) else Right result

encode :: Aeson.Value -> Text
encode = Encoding.decodeUtf8 . Lazy.toStrict . Aeson.encode

-- Graph documents messageReference attachments for chat quotes. replyToId is
-- channel-only. Never infer correlation from quoted HTML or preview text.
reply :: TeamsConfig -> Cursor -> Aeson.Value -> Either Text (Maybe Reply)
reply config cursor value = Right (either (const Nothing) id (candidate True config cursor value))

ordinaryReply :: TeamsConfig -> Cursor -> Aeson.Value -> Either Text (Maybe Reply)
ordinaryReply config cursor value = Right (either (const Nothing) id (candidate False config cursor value))

candidate :: Bool -> TeamsConfig -> Cursor -> Aeson.Value -> Either Text (Maybe Reply)
candidate quoted (TeamsConfig _ chat respondent) (Cursor question created _) value = do
  kind <- field "messageType" value
  deleted <- Json.optionalText "deletedDateTime" value
  if kind /= "message" || deleted /= Nothing then pure Nothing else do
    sender <- case Json.member "from" value >>= Json.member "user" >>= Json.optionalText "id" of
      Right result -> pure result
      Left _ -> pure Nothing
    if sender /= Just respondent then pure Nothing else if not quoted then matched else do
      references <- Json.member "attachments" value >>= Json.array >>= mapM reference
      case nub [key | Just key <- references] of
        [key] | key == question -> matched
        _ -> pure Nothing
  where
    reference attachment = do
      kind <- field "contentType" attachment
      if kind /= "messageReference" then pure Nothing else do
        key <- nonempty "id" attachment
        details <- Json.optionalText "content" attachment
        case details of
          Nothing -> pure ()
          Just content -> do
            referenced <- Json.parse content >>= nonempty "messageId"
            if referenced == key then pure () else Left "Inconsistent Teams quoted-message identity."
        pure (Just key)
    matched = do
      key <- nonempty "id" value
      actualChat <- nonempty "chatId" value
      sent <- nonempty "createdDateTime" value
      sentTime <- timestamp sent
      questionTime <- timestamp created
      if key == question || actualChat /= chat || sentTime <= questionTime then pure Nothing else do
        body <- Json.member "body" value
        kind <- field "contentType" body
        content <- field "content" body
        if kind `elem` ["text","html"] then pure (Just (Reply key respondent sent kind (if kind == "html" then stripQuote question content else content)))
          else Left "Unsupported Teams reply body content type."

-- Remove only the documented placeholder for the correlated quote. Other HTML
-- remains provider content, not a plain-text rendering or sanitized HTML.
stripQuote :: Text -> Text -> Text
stripQuote key = Text.replace ("<attachment id=\"" <> key <> "\"></attachment>") ""
