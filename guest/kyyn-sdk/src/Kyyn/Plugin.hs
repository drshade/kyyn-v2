{-# LANGUAGE FlexibleContexts, TypeOperators, OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Plugin
  ( Connector(..), CapturedMethod(..), Program, concurrently, concurrentlyE, EvidenceSnapshot, FetchError(..), EvidenceId(..), EvidenceFingerprint(..)
  , EvidencePayload(..), Evidence(..), EvidenceChange(..), CapturedText(..), FetchContext(..), FetchResult(..), CapturedRead, Member, listEvidenceIds, readEvidence
  , BlobRef(..), readBlob, readBlobText ) where

import Kyyn.Types.Program (Program, (:+:)(..), Member(..), request, concurrently, concurrentlyE)
import Kyyn.Types.Blob (BlobRef(..), BlobRead(..))
import qualified Data.ByteString as Bytes
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Kyyn.Types.Plugin (EvidenceRead(..))
import Kyyn.Types.Plugin (Connector(..), CapturedMethod(..), EvidenceSnapshot, FetchError(..), CapturedText(..), FetchContext(..), FetchResult(..))
import Kyyn.Types.Evidence (EvidenceId(..), EvidenceFingerprint(..), EvidencePayload(..), Evidence(..), EvidenceChange(..))

-- | A plugin method that reads captured evidence without acquiring new source data.
type CapturedRead payload = Program (EvidenceRead payload :+: BlobRead)

-- | Read bytes reachable from the current captured input; never fetch upstream.
readBlob :: Member BlobRead row => BlobRef -> Program row (Either FetchError Bytes.ByteString)
readBlob = request . inject . ReadBlob

-- | Decode captured bytes strictly as UTF-8; binary content returns a failure.
readBlobText :: Member BlobRead row => BlobRef -> Program row (Either FetchError Text)
readBlobText ref = fmap (>>= decode) (readBlob ref)
  where
    decode bytes | Bytes.isValidUtf8 bytes = Right (Text.decodeUtf8 bytes)
                 | otherwise = Left (FetchError "Blob is not valid UTF-8 text")

-- | List IDs in the selected captured evidence snapshot.
listEvidenceIds :: Member (EvidenceRead payload) row => EvidenceSnapshot payload -> Program row (Either FetchError [EvidenceId])
listEvidenceIds = request . inject . ListEvidenceIds

-- | Read one item from the selected captured evidence snapshot.
readEvidence :: Member (EvidenceRead payload) row => EvidenceSnapshot payload -> EvidenceId
  -> Program row (Either FetchError (Maybe (Evidence payload)))
readEvidence snapshot key = request (inject (ReadEvidence snapshot key))
