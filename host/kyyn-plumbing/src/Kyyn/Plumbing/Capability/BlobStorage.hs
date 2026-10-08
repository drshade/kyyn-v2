{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.BlobStorage
  ( BlobStorage(..), storeBlobAt, readBlobAt, checkBlobsAt, reclaimBlobsAt, blobPathAt, withBlobDownloads, discardBlobsAt ) where

import Data.ByteString (ByteString)
import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Evidence (ConnectorInstanceRef)
import Kyyn.Types.Blob (BlobRef, BlobDownload, BlobResponse)
import Kyyn.Types.Plugin (FetchError)

data BlobStorage :: Effect where
  WithBlobDownloads :: ConnectorInstanceRef -> ([BlobRef] -> Eff es ()) -> Eff es a -> BlobStorage (Eff es) a
  StoreBlobAt :: ConnectorInstanceRef -> BlobDownload -> BlobStorage m (Either FetchError BlobResponse)
  ReadBlobAt :: ConnectorInstanceRef -> BlobRef -> BlobStorage m (Either FetchError ByteString)
  CheckBlobsAt :: ConnectorInstanceRef -> [BlobRef] -> BlobStorage m (Either FetchError ())
  ReclaimBlobsAt :: ConnectorInstanceRef -> [BlobRef] -> BlobStorage m ()
  BlobPathAt :: ConnectorInstanceRef -> BlobRef -> BlobStorage m (Either FetchError FilePath)
  DiscardBlobsAt :: ConnectorInstanceRef -> [BlobRef] -> BlobStorage m ()
type instance DispatchOf BlobStorage = Dynamic

-- | Always finalize with the blobs newly created by this acquisition.
withBlobDownloads :: BlobStorage :> es => ConnectorInstanceRef -> ([BlobRef] -> Eff es ()) -> Eff es a -> Eff es a
withBlobDownloads instanceRef cleanup = send . WithBlobDownloads instanceRef cleanup
discardBlobsAt :: BlobStorage :> es => ConnectorInstanceRef -> [BlobRef] -> Eff es ()
discardBlobsAt instanceRef = send . DiscardBlobsAt instanceRef

storeBlobAt :: BlobStorage :> es => ConnectorInstanceRef -> BlobDownload -> Eff es (Either FetchError BlobResponse)
storeBlobAt instanceRef = send . StoreBlobAt instanceRef
readBlobAt :: BlobStorage :> es => ConnectorInstanceRef -> BlobRef -> Eff es (Either FetchError ByteString)
readBlobAt instanceRef = send . ReadBlobAt instanceRef
checkBlobsAt :: BlobStorage :> es => ConnectorInstanceRef -> [BlobRef] -> Eff es (Either FetchError ())
checkBlobsAt instanceRef = send . CheckBlobsAt instanceRef
-- | Caller holds the instance publication lock and supplies all current references.
reclaimBlobsAt :: BlobStorage :> es => ConnectorInstanceRef -> [BlobRef] -> Eff es ()
reclaimBlobsAt instanceRef = send . ReclaimBlobsAt instanceRef
blobPathAt :: BlobStorage :> es => ConnectorInstanceRef -> BlobRef -> Eff es (Either FetchError FilePath)
blobPathAt instanceRef = send . BlobPathAt instanceRef
