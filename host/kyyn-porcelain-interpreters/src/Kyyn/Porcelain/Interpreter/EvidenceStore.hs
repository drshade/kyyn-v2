{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore) where

import Control.Monad (unless, when)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.ByteString as Bytes
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (contractFingerprint, rootType)
import Kyyn.Domain.Blob (blobReferences)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Plugin (FetchError(..))
import qualified Data.Text as Text
import qualified Kyyn.Plumbing.Capability.BlobStorage as Blobs
import Kyyn.Domain.Evidence
import Kyyn.Domain.KnowledgeBase (cacheLocation)
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.Path (DirectoryScope, scopePath, relativeName, directoryScope, relativePath)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence, DocumentAccess, DocumentStamp(..), withLockedDocument)
import qualified Kyyn.Plumbing.Capability.DocumentPersistence as Document
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Porcelain.Capability.EvidenceStore
import Kyyn.Porcelain.Protocol.EvidencePersistence
import System.FilePath ((</>))

runEvidenceStore :: forall es a. (Blobs.BlobStorage :> es, DocumentPersistence :> es, Failure :> es, DhallHandling :> es, FileSystem.FileSystem :> es)
  => DirectoryScope -> Eff (EvidenceStore : es) a -> Eff es a
runEvidenceStore kb = interpret $ \_ -> \case
  DiscardFetchBlobs instanceRef expected created -> locked instanceRef $ do
    bytes <- Document.readCurrent
    header <- traverse decodeHeader bytes
    let current = case header of
          Nothing -> Right Nothing
          Just (Right (EvidenceHeader _ _ key)) -> Right (Just key)
          Just (Left problem) -> Left problem
    when (current == Right expected) (Blobs.discardBlobsAt instanceRef created)
  BeginFetch instanceRef producer contract positionContract -> locked instanceRef $ runExceptT $ do
    DocumentStamp _ started <- ExceptT (Right <$> Document.freshStamp)
    bytes <- readCurrent
    header <- traverse (ExceptT . decodeHeader) bytes
    let base = case header of Just (EvidenceHeader _ _ key) -> Just key; Nothing -> Nothing
    case (maybe False (matches producer) header,bytes) of
      (True,Just contents) -> do
        EvidenceState latest@(FetchSummary identity _ _ _ _ _) values <- ExceptT (decodeState producer contract contents)
        let snapshot = EvidenceSnapshotRef instanceRef producer identity
        position <- traverse (\selected -> ExceptT (decodePosition selected contents)) positionContract
        pure (FetchBaseline started base (Just (CurrentEvidence snapshot values latest)) position)
      _ -> pure (FetchBaseline started base Nothing Nothing)
  EvidenceHead instanceRef -> locked instanceRef $ runExceptT $ do
    bytes <- readCurrent
    traverse (fmap (\(EvidenceHeader _ _ current) -> current) . ExceptT . decodeHeader) bytes
  PublishFetch instanceRef producer contract expected options changes position -> locked instanceRef $ runExceptT $ do
    bytes <- readCurrent
    header <- traverse (ExceptT . decodeHeader) bytes
    let current = case header of Just (EvidenceHeader _ _ key) -> Just key; Nothing -> Nothing
    unless (current == expected) (throwE BaseSnapshotConflict)
    values <- case (maybe False (matches producer) header,bytes) of
      (True,Just contents) -> do
        EvidenceState _ values <- ExceptT (decodeState producer contract contents)
        pure values
      _ -> pure []
    next <- liftEither (applyChanges values changes)
    DocumentStamp key at <- ExceptT (Right <$> freshFetchStamp current)
    let count = toInteger . length
        identity = FetchId key
        updated = EvidenceState (FetchSummary identity at
          (count [() | NewEvidence _ _ <- changes])
          (count [() | UpdatedEvidence _ _ <- changes])
          (count [() | RemovedEvidence _ <- changes]) options) next
    encoded <- ExceptT (encodeStateWithPosition producer contract updated position)
    refs <- either (throwE . InvalidEvidence) pure (concat <$> traverse (blobReferences (rootType contract))
      [value | (_,Evidence _ _ (Available (CheckedValue _ value))) <- next])
    ExceptT (fmap (either (\(FetchError message) -> Left (InvalidEvidence (Text.unpack message))) Right)
      (Blobs.checkBlobsAt instanceRef refs))
    ExceptT $ Right <$> FileSystem.ensureIgnoredDirectory kb cacheLocation
    ExceptT $ Right <$> Document.replaceCurrent encoded
    ExceptT $ Right <$> Blobs.reclaimBlobsAt instanceRef refs
    pure (EvidenceSnapshotRef instanceRef producer identity)
  LoadCurrentEvidence instanceRef producer contract -> locked instanceRef $ runExceptT $ do
    bytes <- readCurrent
    traverse (\contents -> do
      EvidenceState latest@(FetchSummary identity _ _ _ _ _) values <- ExceptT (decodeState producer contract contents)
      let snapshot = EvidenceSnapshotRef instanceRef producer identity
      pure (CurrentEvidence snapshot values latest)) bytes
  ClearEvidence instanceRef -> locked instanceRef Document.clearCurrent
  where
    locked :: ConnectorInstanceRef -> Eff (DocumentAccess : es) b -> Eff es b
    locked instanceRef action =
      let path = scopePath kb </> relativeName cacheLocation </> "evidence" </> instancePath instanceRef
      in case directoryScope path of
        Left message -> raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.InspectEntry path message))
        Right scope -> withLockedDocument scope (either error id (relativePath "state.dhall")) action

type Result es = ExceptT EvidenceProblem (Eff es)

freshFetchStamp :: DocumentAccess :> es => Maybe FetchId -> Eff es DocumentStamp
freshFetchStamp current = do
  stamp@(DocumentStamp key _) <- Document.freshStamp
  if current == Just (FetchId key) then freshFetchStamp current else pure stamp

liftEither :: Either EvidenceProblem a -> Result es a
liftEither = either throwE pure

matches :: EvidenceProducer -> EvidenceHeader -> Bool
matches (EvidenceProducer producer contract) (EvidenceHeader stored fingerprint _) =
  stored == producer && fingerprint == contractFingerprint contract

readCurrent :: DocumentAccess :> es => Result es (Maybe Bytes.ByteString)
readCurrent = ExceptT (Right <$> Document.readCurrent)
