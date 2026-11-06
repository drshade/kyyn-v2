{-# LANGUAGE GADTs, DuplicateRecordFields, NoFieldSelectors, TypeApplications, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Types.Blob
  ( BlobRef(..), blobCodec, BlobDownload(..), BlobResponse(..), BlobAcquisition(..), BlobRead(..) ) where

import Agentic.Contract
import qualified Agentic.Codec as C
import Agentic.Value (Value(..))
import qualified Data.Text as T
import Kyyn.Types.Scalar (textual, integerText)
import Data.List (sort)
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

-- | The caller supplies the structural optional codec so this leaf obeys the
-- selected projection's null/tag policy without losing BlobRef's scalar identity.
blobCodec :: Codec (Maybe Text) -> Codec BlobRef
blobCodec optionalText = Codec fields.schema fields.encode $ \value -> case value of
  Object values | sort (map fst values) == ["mediaType","name","sha256","size"] -> fields.decode value
  _ -> Left "expected exactly the BlobRef fields: sha256, size, mediaType, name"
  where
    fields = C.record "" $ BlobRef <$> C.requiredWith "sha256" Nothing digest (\(BlobRef x _ _ _) -> x)
          <*> C.requiredWith "size" Nothing size (\(BlobRef _ x _ _) -> x)
          <*> C.requiredWith "mediaType" Nothing text (\(BlobRef _ _ x _) -> x)
          <*> C.requiredWith "name" Nothing optionalText (\(BlobRef _ _ _ x) -> x)
    text = textual id Right
    digest = textual id $ \t -> if T.length t == 64 && T.all (`elem` ("0123456789abcdef" :: String)) t
      then Right t else Left "expected a lowercase SHA-256 digest"
    size = textual (T.pack . show) $ \t -> do
      n <- integerText.decode (String t)
      if n < 0 then Left "blob size must be nonnegative" else Right n

instance Contract BlobRef where
  contract = scalar (ScalarInfo "Kyyn.BlobRef" []) model
    where model = either (const Nothing) (Just . blobCodec) (compileModel (contract @(Maybe Text)))
