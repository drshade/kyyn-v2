{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Mail.Api (baseUrl, folderId, delta, captureMessage, textField) where

import Data.Text (Text)
import qualified Data.Text as Text
import Control.Monad (forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Kyyn.Plugin.Host
import MicrosoftGraph.Mail.Types (MailFolder(..), Message(..), Attachment(..), AttachmentContent(..))
import MicrosoftGraph.Types (Person(..))
import qualified MicrosoftGraph.Http as Http
import qualified MicrosoftGraph.Json as Json
import Text.JSON.Types (JSValue(..), fromJSObject)

baseUrl :: Text -> Text
baseUrl mailbox = "https://graph.microsoft.com/v1.0/users/" <> Json.escape mailbox

requestHeaders :: Text -> [(Text,Text)]
requestHeaders token = [("Authorization","Bearer " <> token),
  ("Prefer","IdType=\"ImmutableId\", outlook.body-content-type=\"text\", odata.maxpagesize=100")]

get :: Text -> Text -> Acquisition payload (Either Text HttpResponse)
get token url
  | "https://graph.microsoft.com/v1.0/" `Text.isPrefixOf` url = Http.send (HttpRequest "GET" url (requestHeaders token) "")
  | otherwise = pure (Left "Unexpected Graph pagination URL")

document :: Text -> Text -> Acquisition payload (Either Text JSValue)
document token url = fmap (\response -> response >>= Http.requireSuccess >>= Json.parse) (get token url)

collection :: Text -> Text -> Acquisition payload (Either Text [JSValue])
collection token = runExceptT . pages []
  where
    pages seen url
      | url `elem` seen = throwE "Graph pagination repeated a page"
      | otherwise = do
          value <- ExceptT (document token url)
          entries <- either throwE pure (Json.member "value" value >>= Json.array)
          next <- either throwE pure (Json.optionalText "@odata.nextLink" value)
          rest <- maybe (pure []) (pages (url:seen)) next
          pure (entries ++ rest)

folderId :: Text -> Text -> MailFolder -> Acquisition payload (Either Text Text)
folderId token base (WellKnownFolder name) = fmap (>>= textField "id")
  (document token (base <> "/mailFolders/" <> Json.escape name <> "?$select=id"))
folderId token base (FolderPath path) = runExceptT (walk (base <> "/mailFolders") (Text.splitOn "/" path))
  where
    walk _ [] = throwE "Empty folder path"
    walk url (name:rest) = do
      entries <- ExceptT (collection token (url <> "?$select=id,displayName"))
      matches <- either throwE pure $ traverse (\v -> (,) <$> textField "displayName" v <*> textField "id" v) entries
      key <- case [key | (display,key) <- matches, display == name] of
        [key] -> pure key
        [] -> throwE ("Mail folder not found: " <> name)
        _ -> throwE ("Mail folder path is ambiguous: " <> name)
      if null rest then pure key else walk (base <> "/mailFolders/" <> Json.escape key <> "/childFolders") rest

delta :: Text -> Text -> Acquisition payload (Either Text (Maybe ([JSValue],Text)))
delta token = runExceptT . pages []
  where
    pages seen url
      | url `elem` seen = throwE "Mail delta pagination repeated a page"
      | otherwise = do
          response@(HttpResponse status _ body) <- ExceptT (get token url)
          let expired = case Json.parse body >>= Json.member "error" >>= textField "code" of
                Right code -> Text.toLower code `elem` ["syncstatenotfound", "invaliddeltatoken"]
                Left _ -> False
          if status == 410 || (status >= 400 && expired) then pure Nothing else do
            value <- either throwE pure (Http.requireSuccess response >>= Json.parse)
            entries <- either throwE pure (Json.member "value" value >>= Json.array)
            next <- either throwE pure (Json.optionalText "@odata.nextLink" value)
            case next of
              Just link -> fmap (fmap (\(more,final) -> (entries ++ more,final))) (pages (url:seen) link)
              Nothing -> do
                final <- either throwE pure (textField "@odata.deltaLink" value)
                if "https://graph.microsoft.com/v1.0/" `Text.isPrefixOf` final then pure (Just (entries,final))
                  else throwE "Unexpected Graph delta URL"

captureMessage :: Text -> Text -> Text -> Text -> Acquisition Message (Either Text Message)
captureMessage token base folder key = runExceptT $ do
  let url = base <> "/messages/" <> Json.escape key
  value <- ExceptT (document token (url <> "?$select=subject,from,toRecipients,ccRecipients,sentDateTime,receivedDateTime,conversationId,internetMessageId,body"))
  bodyValue <- either throwE pure (Json.member "body" value)
  bodyType <- either throwE pure (textField "contentType" bodyValue)
  if Text.toLower bodyType /= "text" then throwE "Graph returned a non-text mail body despite Prefer; capture refused" else pure ()
  metadata <- ExceptT (collection token (url <> "/attachments?$select=id,name,contentType,size,isInline"))
  attachments <- forM metadata $ \attachment -> do
    identity <- either throwE pure (textField "id" attachment)
    kind <- either throwE pure (textField "@odata.type" attachment)
    name <- either throwE pure (descriptive "name" attachment)
    media <- either throwE pure (descriptive "contentType" attachment)
    size <- either throwE pure (Json.optionalInteger "size" 0 attachment)
    inline <- either throwE pure (case optional "isInline" attachment of JSNull -> Right False; v -> Json.boolean v)
    let endpoint = url <> "/attachments/" <> Json.escape identity
    case kind of
      "#microsoft.graph.referenceAttachment" -> pure (Attachment name media (toInteger size) inline (Link endpoint))
      _ | kind `elem` ["#microsoft.graph.fileAttachment","#microsoft.graph.itemAttachment"] -> do
        ref@(BlobRef _ actualSize actualMedia _) <- ExceptT (Http.download
          (BlobDownload (HttpRequest "GET" (endpoint <> "/$value") (requestHeaders token) "") (Just name) Nothing))
        pure (Attachment name actualMedia actualSize inline (Stored ref))
      _ -> throwE ("Unsupported Graph attachment kind: " <> kind)
  either throwE pure $ Message <$> descriptive "subject" value <*> person (optional "from" value)
    <*> people "toRecipients" value <*> people "ccRecipients" value
    <*> textField "sentDateTime" value <*> textField "receivedDateTime" value
    <*> descriptive "conversationId" value <*> descriptive "internetMessageId" value
    <*> pure folder <*> textField "content" bodyValue <*> pure attachments

textField :: Text -> JSValue -> Either Text Text
textField name value = Json.member name value >>= Json.text
descriptive :: Text -> JSValue -> Either Text Text
descriptive name value = maybe "" id <$> Json.optionalText name value
optional :: Text -> JSValue -> JSValue
optional name (JSObject fields) = maybe JSNull id (lookup (Text.unpack name) (fromJSObject fields))
optional _ _ = JSNull
person :: JSValue -> Either Text Person
person JSNull = Right (Person "" "")
person value = do
  email <- Json.member "emailAddress" value
  Person <$> descriptive "name" email <*> descriptive "address" email
people :: Text -> JSValue -> Either Text [Person]
people name value = case optional name value of JSNull -> Right []; entries -> Json.array entries >>= mapM person
