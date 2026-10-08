{-# LANGUAGE GADTs, DuplicateRecordFields, NoFieldSelectors #-}
module Kyyn.Types.Blob
  ( BlobRef(..), BlobDownload(..), BlobResponse(..), BlobAcquisition(..), BlobRead(..) ) where

import Data.Text (Text)
import Data.ByteString (ByteString)
import Kyyn.Types.Plugin (FetchError)
import Kyyn.Types.PluginHost (HttpRequest)

-- | Captured bytes in the selected connector's local store. Names are not paths.
data BlobRef = BlobRef
  { sha256 :: Text, size :: Integer, mediaType :: Text, name :: Maybe Text }
  deriving (Eq, Show)

-- | Stream a response to host storage without passing its bytes through the guest.
data BlobDownload = BlobDownload
  { request :: HttpRequest, name :: Maybe Text, mediaType :: Maybe Text }

-- | HTTP status and headers are available even when no blob was downloaded.
data BlobResponse = BlobResponse
  { status :: Int, headers :: [(Text,Text)], blob :: Maybe BlobRef }
  deriving (Eq, Show)

data BlobAcquisition a where
  StoreBlob :: BlobDownload -> BlobAcquisition (Either FetchError BlobResponse)

data BlobRead a where
  ReadBlob :: BlobRef -> BlobRead (Either FetchError ByteString)
