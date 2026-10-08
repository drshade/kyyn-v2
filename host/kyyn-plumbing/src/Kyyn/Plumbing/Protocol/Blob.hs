{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Plumbing.Protocol.Blob (decodeDownload, downloadResult) where

import Data.Aeson (Value, object, (.=), (.:))
import Data.Aeson.Types (Parser, withObject)
import qualified Data.ByteString as Bytes
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Blob (blobValue)
import Kyyn.Types.Blob (BlobDownload(..), BlobResponse(..))
import Kyyn.Types.PluginHost (HttpRequest(..))
import Kyyn.Types.Plugin (FetchError(..))

decodeDownload :: Bytes.ByteString -> Value -> Parser BlobDownload
decodeDownload raw = withObject "blob download" $ \o -> do
  body <- either (const (fail "Invalid UTF-8 download request body")) pure (Text.decodeUtf8' raw)
  request <- HttpRequest <$> o .: "method" <*> o .: "url"
    <*> (o .: "headers" >>= traverse (withObject "header" (\h -> (,) <$> h .: "name" <*> h .: "value"))) <*> pure body
  BlobDownload request <$> (o .: "name" >>= optional) <*> (o .: "mediaType" >>= optional)
  where
    optional = withObject "optional text" $ \o -> do
      tag <- o .: "tag"
      case tag :: String of
        "None" -> pure Nothing
        "Some" -> Just <$> o .: "value"
        _ -> fail "Invalid optional text"

downloadResult :: Either FetchError BlobResponse -> Value
downloadResult (Left (FetchError message)) = object ["tag" .= ("Left" :: String),"value" .= message]
downloadResult (Right (BlobResponse status headers blob)) = object ["tag" .= ("Right" :: String),"value" .= object
  ["status" .= show status,"headers" .= [object ["name" .= name,"value" .= value] | (name,value) <- headers],
   "blob" .= maybe (object ["tag" .= ("None" :: String)])
     (\ref -> object ["tag" .= ("Some" :: String),"value" .= blobValue ref]) blob]]
