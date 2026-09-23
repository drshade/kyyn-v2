{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Domain.Evidence
  ( EvidenceId(..), EvidenceFingerprint(..), FetchId(..), ConnectorInstanceRef(..), EvidenceProducer(..)
  , Evidence(..), EvidenceChange(..), Fetch(..), EvidenceState(..), CurrentEvidence(..)
  , EvidenceSnapshotRef(..), EvidenceProblem(..), ChangeKind(..), EvidenceChangeMarker(..), EvidenceChangeSummary(..)
  , applyChanges, recordChanges, fetchesSince, summarizeChanges, validateState
  , evidenceProblemDiagnostic, FetchSummary(..), summarizeFetch
  , EvidenceCapture(..), captureEvidence, resolveCapture
  ) where

import Control.Monad (foldM, unless)
import Data.List (nub)
import Kyyn.Domain.Plugin (PluginName, pluginNameText, PackageIdentity)
import Kyyn.Domain.Contract (ContractId)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Types.Evidence (EvidenceRef(..), EvidenceId(..), EvidenceFingerprint(..), Evidence(..), EvidenceChange(..))

newtype FetchId = FetchId String deriving (Eq, Show)
data ConnectorInstanceRef = ConnectorInstanceRef PluginName String deriving (Eq, Show)
data EvidenceProducer = EvidenceProducer PackageIdentity ContractId deriving (Eq, Show)
data Fetch = Fetch
  { identity :: FetchId, previous :: Maybe FetchId, fetchedAt :: String
  , changes :: [EvidenceChangeMarker]
  } deriving (Eq, Show)
data FetchSummary = FetchSummary FetchId (Maybe FetchId) String Int deriving (Eq, Show)

summarizeFetch :: Fetch -> FetchSummary
summarizeFetch (Fetch identity previous at changes) = FetchSummary identity previous at (length changes)

data EvidenceState a = EvidenceState
  { current :: Maybe FetchId, values :: [(EvidenceId, Evidence a)], history :: [Fetch]
  } deriving (Eq, Show)
data CurrentEvidence = CurrentEvidence
  { snapshot :: EvidenceSnapshotRef, items :: [(EvidenceId, Evidence CheckedValue)]
  } deriving (Eq, Show)
data EvidenceCapture = EvidenceCapture EvidenceSnapshotRef [(EvidenceId, EvidenceFingerprint)] deriving (Eq, Show)

captureEvidence :: CurrentEvidence -> EvidenceCapture
captureEvidence (CurrentEvidence snapshot items) = EvidenceCapture snapshot
  [(item,token) | (item,Evidence token _ _) <- items]

resolveCapture :: ConnectorInstanceRef -> EvidenceProducer -> FetchId -> [Fetch] -> FetchId
  -> Either EvidenceProblem EvidenceCapture
resolveCapture instanceRef producer current history selected = do
  values <- foldM applyMarker [] [marker | Fetch _ _ _ markers <- history, marker <- markers]
  validateState (EvidenceState (Just current) values history)
  prefix <- through history
  selectedValues <- foldM applyMarker [] [marker | Fetch _ _ _ markers <- prefix, marker <- markers]
  pure (EvidenceCapture (EvidenceSnapshotRef instanceRef producer selected)
    [(item,token) | (item,Evidence token _ _) <- selectedValues])
  where
    through [] = Left CursorUnavailable
    through (entry@(Fetch identity _ _ _) : rest)
      | identity == selected = Right [entry]
      | otherwise = (entry :) <$> through rest
    applyMarker entries (EvidenceChangeMarker kind key token (EvidenceRef _ _ _ refs)) =
      either (Left . InvalidEvidence . show) Right $ applyChanges entries [case kind of
        New -> NewEvidence key (Evidence token refs ())
        Updated -> UpdatedEvidence key (Evidence token refs ())
        Removed -> RemovedEvidence key]
data EvidenceSnapshotRef = EvidenceSnapshotRef ConnectorInstanceRef EvidenceProducer FetchId deriving (Eq, Show)
data EvidenceProblem = CursorUnavailable | NotFetched | ProducerContractChanged
  | BaseSnapshotConflict | InvalidDelta String | InvalidEvidence String
  deriving (Eq, Show)

evidenceProblemDiagnostic :: EvidenceProblem -> Diagnostic
evidenceProblemDiagnostic problem = case problem of
  CursorUnavailable -> errorDiagnostic "evidence.cursor-unavailable"
    "The evidence cursor is unavailable. Reconcile against current evidence and record a new cursor."
  NotFetched -> errorDiagnostic "evidence.not-fetched"
    "This connector has no captured evidence. Fetch it before reading its evidence."
  ProducerContractChanged -> errorDiagnostic "evidence.producer-changed"
    "The plugin source or evidence schema has changed. Fetch this connector again before reading its evidence."
  BaseSnapshotConflict -> errorDiagnostic "evidence.base-conflict"
    "Another fetch advanced this connector while acquisition was running. Retry against its new head."
  InvalidDelta message -> errorDiagnostic "evidence.invalid-delta" message
  InvalidEvidence message -> errorDiagnostic "evidence.invalid-data"
    (message ++ " Clear this instance with evidence clear PLUGIN INSTANCE, then fetch it again.")

data ChangeKind = New | Updated | Removed deriving (Eq, Show)
data EvidenceChangeMarker = EvidenceChangeMarker
  { kind :: ChangeKind, item :: EvidenceId, fingerprint :: EvidenceFingerprint, citation :: EvidenceRef
  } deriving (Eq, Show)
data EvidenceChangeSummary = EvidenceChangeSummary
  { fetch :: FetchId, previous :: Maybe FetchId, kind :: ChangeKind
  , item :: EvidenceId, fingerprint :: EvidenceFingerprint, citation :: EvidenceRef
  } deriving (Eq, Show)

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
    missing key = not . any ((== key) . fst)
    valid (EvidenceId key) | null key = Left (InvalidDelta "Evidence ID must not be empty")
                          | otherwise = Right ()
    fingerprint (Evidence token _ _) = token
    validFingerprint (Evidence (EvidenceFingerprint token) _ _)
      | null token = Left (InvalidDelta "Evidence fingerprint must not be empty")
      | otherwise = Right ()

recordChanges :: ConnectorInstanceRef -> [(EvidenceId, Evidence a)] -> [EvidenceChange a]
  -> Either EvidenceProblem ([(EvidenceId, Evidence a)], [EvidenceChangeMarker])
recordChanges (ConnectorInstanceRef plugin instanceName) initial = foldM step (initial,[])
  where
    step (values,markers) change = do
      next <- applyChanges values [change]
      (key@(EvidenceId source),kind,value) <- case change of
        NewEvidence key value -> pure (key,New,value)
        UpdatedEvidence key value -> pure (key,Updated,value)
        RemovedEvidence key -> maybe (Left (InvalidDelta "Removed evidence ID is missing"))
          (\value -> pure (key,Removed,value)) (lookup key values)
      let Evidence fingerprint refs _ = value
      pure (next,markers ++ [EvidenceChangeMarker kind key fingerprint
        (EvidenceRef (pluginNameText plugin) instanceName source refs)])

fetchesSince :: EvidenceState a -> Maybe FetchId -> Either EvidenceProblem [Fetch]
fetchesSince (EvidenceState _ _ history) = maybe (Right history) after
  where
    after key = go history
      where
        go [] = Left CursorUnavailable
        go (Fetch identity _ _ _:rest) | identity == key = Right rest
                                     | otherwise = go rest

summarizeChanges :: [Fetch] -> [EvidenceChangeSummary]
summarizeChanges fetches =
  [EvidenceChangeSummary identity previous kind key fingerprint citation |
    Fetch identity previous _ markers <- fetches,
    EvidenceChangeMarker kind key fingerprint citation <- markers]

validateState :: EvidenceState a -> Either EvidenceProblem ()
validateState (EvidenceState current values history) = do
  let ids = [key | Fetch key _ _ _ <- history]
      memberIds = map fst values
      validMember (EvidenceId key,Evidence (EvidenceFingerprint token) _ _) = not (null key || null token)
      validMarker (EvidenceChangeMarker _ (EvidenceId key) (EvidenceFingerprint token) _) = not (null key || null token)
  unless (length ids == length (nub ids) && all (\(FetchId key) -> not (null key)) ids &&
    length memberIds == length (nub memberIds) && all validMember values &&
    all (\(Fetch _ _ _ markers) -> all validMarker markers) history)
    (Left (InvalidEvidence "Invalid or duplicate evidence/fetch identities or fingerprints"))
  latest <- foldM (\expected (Fetch identity previous _ _) ->
    if previous == expected then Right (Just identity) else Left (InvalidEvidence "Broken fetch marker chain")) Nothing history
  unless (current == latest && (current /= Nothing || null values))
    (Left (InvalidEvidence "Current evidence and fetch marker head disagree"))
  recorded <- foldM applyMarker [] [marker | Fetch _ _ _ markers <- history, marker <- markers]
  unless (recorded == [(key,metadata value) | (key,value) <- values])
    (Left (InvalidEvidence "Current evidence identities/fingerprints disagree with change markers"))
  where
    metadata (Evidence token refs _) = Evidence token refs ()
    applyMarker entries (EvidenceChangeMarker kind key token (EvidenceRef _ _ source refs)) = do
      unless (key == EvidenceId source) (Left (InvalidEvidence "Change citation differs from evidence identity"))
      let value = Evidence token refs ()
      change <- case kind of
        New -> pure (NewEvidence key value)
        Updated -> pure (UpdatedEvidence key value)
        Removed -> do
          unless (lookup key entries == Just value) (Left (InvalidEvidence "Removal metadata differs from current item"))
          pure (RemovedEvidence key)
      either (Left . InvalidEvidence . show) Right (applyChanges entries [change])
