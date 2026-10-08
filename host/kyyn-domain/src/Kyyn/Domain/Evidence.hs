{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Domain.Evidence
  ( EvidenceId(..), EvidenceFingerprint(..), FetchId(..), ConnectorInstanceRef(..), EvidenceProducer(..)
  , EvidencePayload(..), Evidence(..), EvidenceChange(..), EvidenceState(..), CurrentEvidence(..), FetchSummary(..)
  , EvidenceSnapshotRef(..), EvidenceProblem(..), applyChanges, validateState
  , evidenceProblemDiagnostic, EvidenceCapture(..), captureEvidence, SyncMode(..)
  ) where

import Control.Monad (foldM, unless)
import Data.List (nub)
import qualified Data.Text as Text
import Kyyn.Domain.Plugin (PluginName, PackageIdentity)
import Kyyn.Domain.Contract (ContractId)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Types.Evidence (EvidenceId(..), EvidenceFingerprint(..), EvidencePayload(..), Evidence(..), EvidenceChange(..))

newtype FetchId = FetchId String deriving (Eq, Show)
data SyncMode = ContinueSync | RestartSync deriving (Eq, Show)
data ConnectorInstanceRef = ConnectorInstanceRef PluginName String deriving (Eq, Show)
data EvidenceProducer = EvidenceProducer PackageIdentity ContractId deriving (Eq, Show)
data FetchSummary = FetchSummary
  { identity :: FetchId, fetchedAt :: String, added :: Integer, updated :: Integer, removed :: Integer, suppliedOptions :: Maybe String
  } deriving (Eq, Show)
data EvidenceState a = EvidenceState
  { latest :: FetchSummary, values :: [(EvidenceId, Evidence a)]
  } deriving (Eq, Show)
data CurrentEvidence = CurrentEvidence
  { snapshot :: EvidenceSnapshotRef, items :: [(EvidenceId, Evidence CheckedValue)], latest :: FetchSummary
  } deriving (Eq, Show)
data EvidenceCapture = EvidenceCapture EvidenceSnapshotRef FetchSummary [(EvidenceId, EvidenceFingerprint, EvidencePayload ())] deriving (Eq, Show)

captureEvidence :: CurrentEvidence -> EvidenceCapture
captureEvidence (CurrentEvidence snapshot items latest) = EvidenceCapture snapshot latest
  [(item,token,case payload of Available _ -> Available (); Truncated -> Truncated) | (item,Evidence token _ payload) <- items]

data EvidenceSnapshotRef = EvidenceSnapshotRef ConnectorInstanceRef EvidenceProducer FetchId deriving (Eq, Show)
data EvidenceProblem = NotFetched | ProducerContractChanged
  | BaseSnapshotConflict | InvalidDelta String | InvalidEvidence String
  deriving (Eq, Show)

evidenceProblemDiagnostic :: EvidenceProblem -> Diagnostic
evidenceProblemDiagnostic problem = case problem of
  NotFetched -> errorDiagnostic "evidence.not-fetched"
    "This connector has no captured evidence. Fetch it before reading its evidence."
  ProducerContractChanged -> errorDiagnostic "evidence.producer-changed"
    "The plugin source or evidence schema has changed. Fetch this connector again before reading its evidence."
  BaseSnapshotConflict -> errorDiagnostic "evidence.base-conflict"
    "Another fetch advanced this connector while acquisition was running. Retry against its new head."
  InvalidDelta message -> errorDiagnostic "evidence.invalid-delta" message
  InvalidEvidence message -> errorDiagnostic "evidence.invalid-data"
    (message ++ " Clear this instance with evidence clear PLUGIN INSTANCE, then fetch it again.")

applyChanges :: [(EvidenceId, Evidence a)] -> [EvidenceChange a]
  -> Either EvidenceProblem [(EvidenceId, Evidence a)]
applyChanges = foldM step
  where
    step values change = case change of
      NewEvidence key value | missing key values -> valid key >> validFingerprint value >> pure (values ++ [(key,value)])
                            | otherwise -> Left (InvalidDelta "New evidence ID already exists")
      UpdatedEvidence key value | missing key values -> Left (InvalidDelta "Updated evidence ID is missing")
                                | Just (fingerprint value) == (fingerprint <$> lookup key values) ->
                                    Left (InvalidDelta "Updated evidence fingerprint is unchanged")
                                | otherwise -> validFingerprint value >> pure [(k,if k == key then value else v) | (k,v) <- values]
      RemovedEvidence key | missing key values -> Left (InvalidDelta "Removed evidence ID is missing")
                          | otherwise -> pure [(k,v) | (k,v) <- values, k /= key]
      SetEvidencePayload key expected payload -> case lookup key values of
        Nothing -> Left (InvalidDelta "Payload evidence ID is missing")
        Just (Evidence token refs _)
          | token /= expected -> Left (InvalidDelta "Payload evidence fingerprint does not match")
          | otherwise -> pure [(k,if k == key then Evidence token refs payload else v) | (k,v) <- values]
    missing key = not . any ((== key) . fst)
    valid (EvidenceId key) | Text.null key = Left (InvalidDelta "Evidence ID must not be empty")
                          | otherwise = Right ()
    fingerprint (Evidence token _ _) = token
    validFingerprint (Evidence (EvidenceFingerprint token) _ _)
      | Text.null token = Left (InvalidDelta "Evidence fingerprint must not be empty")
      | otherwise = Right ()


validateState :: EvidenceState a -> Either EvidenceProblem ()
validateState (EvidenceState (FetchSummary (FetchId key) at added updated removed _) values) = do
  let ids = map fst values
      validMember (EvidenceId ident,Evidence (EvidenceFingerprint token) _ _) = not (Text.null ident || Text.null token)
  unless (not (null key || null at) && all (>= 0) [added,updated,removed])
    (Left (InvalidEvidence "Invalid latest fetch summary"))
  unless (length ids == length (nub ids) && all validMember values)
    (Left (InvalidEvidence "Invalid or duplicate evidence identities or fingerprints"))
