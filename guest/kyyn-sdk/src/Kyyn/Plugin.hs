{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, TypeOperators, OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Plugin
  ( Connector(..), CapturedMethod(..), Program, EvidenceSnapshot, FetchError(..), EvidenceId(..), EvidenceFingerprint(..)
  , EvidencePayload(..), Evidence(..), EvidenceChange(..), CapturedText(..), FetchContext(..), FetchResult(..), CapturedRead, ReadsEvidence, listEvidenceIds, readEvidence
  , BlobRef(..), readBlob, readBlobText ) where

import Kyyn.Types.Program (Program, (:+:)(..), request)
import Kyyn.Types.PluginHost (Http, Secrets, Waiting, ContentDigest)
import Kyyn.Types.Blob (BlobRef(..), BlobRead(..), BlobAcquisition)
import qualified Data.ByteString as Bytes
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Kyyn.Types.Plugin (EvidenceRead(..), FileRead)
import Kyyn.Types.Plugin (Connector(..), CapturedMethod(..), EvidenceSnapshot, FetchError(..), CapturedText(..), FetchContext(..), FetchResult(..))
import Kyyn.Types.Evidence (EvidenceId(..), EvidenceFingerprint(..), EvidencePayload(..), Evidence(..), EvidenceChange(..))

-- | A plugin method that reads captured evidence without acquiring new source data.
type CapturedRead payload = Program (EvidenceRead payload :+: BlobRead)

-- | Read bytes reachable from the current captured input; never fetch upstream.
readBlob :: BlobRef -> CapturedRead payload (Either FetchError Bytes.ByteString)
readBlob = request . InRight . ReadBlob

-- | Decode captured bytes strictly as UTF-8; binary content returns a failure.
readBlobText :: BlobRef -> CapturedRead payload (Either FetchError Text)
readBlobText ref = fmap (>>= decode) (readBlob ref)
  where
    decode bytes | Bytes.isValidUtf8 bytes = Right (Text.decodeUtf8 bytes)
                 | otherwise = Left (FetchError "Blob is not valid UTF-8 text")

-- | Evidence-reading operations shared by acquisition and captured-read programs.
class ReadsEvidence row payload where
  injectEvidence :: EvidenceRead payload a -> row a

instance ReadsEvidence (EvidenceRead payload :+: BlobRead) payload where
  injectEvidence = InLeft

instance ReadsEvidence (Http :+: (Secrets :+: (Waiting :+: (FileRead :+: (BlobAcquisition :+: (ContentDigest :+: EvidenceRead payload)))))) payload where
  injectEvidence = InRight . InRight . InRight . InRight . InRight . InRight

-- | List IDs in the selected captured evidence snapshot.
listEvidenceIds :: ReadsEvidence row payload => EvidenceSnapshot payload -> Program row (Either FetchError [EvidenceId])
listEvidenceIds = request . injectEvidence . ListEvidenceIds

-- | Read one item from the selected captured evidence snapshot.
readEvidence :: ReadsEvidence row payload => EvidenceSnapshot payload -> EvidenceId
  -> Program row (Either FetchError (Maybe (Evidence payload)))
readEvidence snapshot key = request (injectEvidence (ReadEvidence snapshot key))
