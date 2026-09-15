{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Numeric (showHex)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (CheckedContract, contractFingerprint)
import Kyyn.Domain.Evidence
import Kyyn.Domain.KnowledgeBase (cacheLocation)
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.Path (DirectoryScope, scopePath, relativeName, directoryScope)
import Kyyn.Domain.Plugin (pluginNameText)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence, DocumentAccess, DocumentStamp(..), withLockedDocument)
import qualified Kyyn.Plumbing.Capability.DocumentPersistence as Document
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Porcelain.Capability.EvidenceStore
import Kyyn.Porcelain.Protocol.EvidencePersistence
import System.FilePath ((</>))

runEvidenceStore :: forall es a. (DocumentPersistence :> es, Failure :> es, DhallHandling :> es, FileSystem.FileSystem :> es)
  => DirectoryScope -> Eff (EvidenceStore : es) a -> Eff es a
runEvidenceStore kb = interpret $ \_ -> \case
  EvidenceHead instanceRef -> locked instanceRef $ runExceptT $ do
    bytes <- readCurrent
    case bytes of
      Nothing -> pure Nothing
      Just contents -> do
        EvidenceHeader _ _ current _ _ <- ExceptT (decodeHeader contents)
        pure current
  PublishFetch instanceRef producer contract expected changes -> locked instanceRef $ runExceptT $ do
    bytes <- readCurrent
    header <- traverse (ExceptT . decodeHeader) bytes
    let current = case header of Just (EvidenceHeader _ _ key _ _) -> key; Nothing -> Nothing
    unless (current == expected) (throwE BaseSnapshotConflict)
    let same = maybe False (matches producer) header
    state <- case (same,bytes) of
      (True,Just contents) -> ExceptT (decodeState producer contract contents)
      _ -> pure (EvidenceState Nothing [] Nothing [] [])
    let EvidenceState baseline initial previous values history = state
    next <- liftEither (applyChanges values changes)
    DocumentStamp key at <- ExceptT (Right <$> Document.freshStamp)
    let identity = FetchId key
    let updated = EvidenceState baseline initial (Just identity) next (history ++ [Fetch identity previous at changes])
    encoded <- ExceptT (encodeState producer contract updated)
    ExceptT $ Right <$> FileSystem.ensureIgnoredDirectory kb cacheLocation
    ExceptT $ Right <$> Document.replaceCurrent encoded
    pure (EvidenceSnapshotRef instanceRef producer identity)
  SelectEvidence instanceRef producer selection -> locked instanceRef $ runExceptT $ do
    contents <- requireCurrent
    header@(EvidenceHeader _ _ current baseline history) <- ExceptT (decodeHeader contents)
    unless (matches producer header) (throwE ProducerContractChanged)
    identity <- case selection of
      CurrentEvidence -> maybe (throwE HistoryUnavailable) pure current
      AtFetch identity | Just identity == baseline || identity `elem` history -> pure identity
                       | otherwise -> throwE HistoryUnavailable
    pure (EvidenceSnapshotRef instanceRef producer identity)
  LoadEvidenceSnapshot snapshot@(EvidenceSnapshotRef instanceRef _ identity) contract -> locked instanceRef $ runExceptT $ do
    state <- load snapshot contract
    liftEither (snapshotAt state identity)
  ReadEvidence snapshot@(EvidenceSnapshotRef instanceRef _ identity) contract key -> locked instanceRef $ runExceptT $ do
    state <- load snapshot contract
    lookup key <$> liftEither (snapshotAt state identity)
  ListEvidenceIds snapshot@(EvidenceSnapshotRef instanceRef _ identity) contract -> locked instanceRef $ runExceptT $ do
    state <- load snapshot contract
    map fst <$> liftEither (snapshotAt state identity)
  ReadFetchesBetween snapshot@(EvidenceSnapshotRef instanceRef _ identity) contract base -> locked instanceRef $ runExceptT $ do
    state <- load snapshot contract
    liftEither (fetchesBetween state identity base)
  ListEvidenceChanges snapshot@(EvidenceSnapshotRef instanceRef _ identity) contract base -> locked instanceRef $ runExceptT $ do
    state <- load snapshot contract
    selected <- liftEither (fetchesBetween state identity base)
    initial <- maybe (pure []) (liftEither . snapshotAt state) base
    liftEither (summarizeChanges instanceRef initial selected)
  DeleteEvidenceHistory instanceRef producer contract -> locked instanceRef $ runExceptT $ do
    contents <- requireCurrent
    state <- ExceptT (decodeState producer contract contents)
    let EvidenceState _ _ current values _ = state
    encoded <- ExceptT (encodeState producer contract (EvidenceState current values current values []))
    ExceptT $ Right <$> Document.replaceCurrent encoded
  ClearEvidence instanceRef -> locked instanceRef $
    Document.clearCurrent
  where
    locked :: ConnectorInstanceRef -> Eff (DocumentAccess : es) b -> Eff es b
    locked instanceRef action =
      let path = scopePath kb </> relativeName cacheLocation </> "evidence" </> instancePath instanceRef
      in case directoryScope path of
        Left message -> raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.InspectEntry path message))
        Right scope -> withLockedDocument scope action

type Result es = ExceptT EvidenceProblem (Eff es)

liftEither :: Either EvidenceProblem a -> Result es a
liftEither = either throwE pure

matches :: EvidenceProducer -> EvidenceHeader -> Bool
matches (EvidenceProducer producer contract) (EvidenceHeader stored fingerprint _ _ _) =
  stored == producer && fingerprint == contractFingerprint contract

load :: (DocumentAccess :> es, DhallHandling :> es)
  => EvidenceSnapshotRef -> CheckedContract -> Result es (EvidenceState CheckedValue)
load (EvidenceSnapshotRef _ producer _) contract = do
  contents <- requireCurrent
  ExceptT (decodeState producer contract contents)

readCurrent :: DocumentAccess :> es => Result es (Maybe Bytes.ByteString)
readCurrent = ExceptT (Right <$> Document.readCurrent)

requireCurrent :: DocumentAccess :> es => Result es Bytes.ByteString
requireCurrent = readCurrent >>= maybe (throwE HistoryUnavailable) pure

instancePath :: ConnectorInstanceRef -> FilePath
instancePath (ConnectorInstanceRef plugin name) = pluginNameText plugin ++ "-" ++
  concatMap (\byte -> let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits)
    (Bytes.unpack (Text.encodeUtf8 (Text.pack name)))
