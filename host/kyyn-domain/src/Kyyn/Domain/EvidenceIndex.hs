{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Domain.EvidenceIndex
  ( EvidenceSelection(..), PayloadLocation(..), EvidenceIndex(..)
  , indexCapture, indexBlobs, indexState, indexedEvidence
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Kyyn.Domain.Blob (BlobRef)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Plugin (PackageIdentity, ConnectorTypeName)

data EvidenceSelection = EvidenceSelection
  { instanceRef :: ConnectorInstanceRef, connectorType :: ConnectorTypeName
  , packageIdentity :: PackageIdentity
  } deriving (Eq, Show)

data PayloadLocation = PayloadLocation
  { sha256 :: Text, size :: Integer, blobs :: [BlobRef]
  } deriving (Eq, Show)

data EvidenceIndex = EvidenceIndex
  { snapshot :: EvidenceSnapshotRef, latest :: FetchSummary
  , payloadContract :: CheckedContract
  , items :: Map.Map Text (Evidence PayloadLocation)
  } deriving (Eq, Show)

indexCapture :: EvidenceIndex -> EvidenceCapture
indexCapture (EvidenceIndex snapshot latest _ items) = EvidenceCapture snapshot latest
  [(EvidenceId key, fingerprint, case payload of Available _ -> Available (); Truncated -> Truncated)
  | (key,Evidence fingerprint _ payload) <- Map.toAscList items]

indexBlobs :: EvidenceIndex -> [BlobRef]
indexBlobs (EvidenceIndex _ _ _ items) = concat
  [refs | Evidence _ _ (Available (PayloadLocation _ _ refs)) <- Map.elems items]

indexState :: EvidenceIndex -> EvidenceState PayloadLocation
indexState (EvidenceIndex _ latest _ items) = EvidenceState latest
  [(EvidenceId key,value) | (key,value) <- Map.toAscList items]

indexedEvidence :: EvidenceIndex -> EvidenceId -> Maybe (Evidence PayloadLocation)
indexedEvidence (EvidenceIndex _ _ _ items) (EvidenceId key) = Map.lookup key items
