{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore) where

import Control.Monad (unless, when)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.ByteString as Bytes
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (catchError)
import Kyyn.Domain.Contract (CheckedContract, contractFingerprint, rootType, contractId)
import Kyyn.Domain.Blob (blobReferences)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Plugin (FetchError(..))
import qualified Data.Text as Text
import qualified Kyyn.Plumbing.Capability.BlobStorage as Blobs
import Kyyn.Domain.Evidence
import Kyyn.Domain.EvidenceIndex (EvidenceIndex(..), EvidenceSelection(..), PayloadLocation(..), indexedEvidence)
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
import Kyyn.Porcelain.Protocol.EvidenceIndex (IndexDocument(..), encodeIndex, decodeIndex, capturedIndex)
import qualified Kyyn.Porcelain.Protocol.EvidencePayload as Payload
import System.FilePath ((</>))

runEvidenceStore :: forall es a. (Blobs.BlobStorage :> es, DocumentPersistence :> es, Failure :> es, DhallHandling :> es, FileSystem.FileSystem :> es)
  => DirectoryScope -> Eff (EvidenceStore : es) a -> Eff es a
runEvidenceStore kb = interpret $ \_ -> \case
  OpenCurrentEvidence (EvidenceSelection instanceRef kind package) -> lockedIndex instanceRef $ runExceptT $ do
    bytes <- indexedBytes instanceRef
    traverse (\contents -> do
      document@(IndexDocument stored selected _ _ _) <- ExceptT (decodeIndex contents)
      unless (stored == package && selected == kind) (throwE ProducerContractChanged)
      pure (capturedIndex instanceRef document)) bytes
  ReadCapturedEvidence index@(EvidenceIndex (EvidenceSnapshotRef instanceRef _ _) _ contract _) key -> runExceptT $
    case indexedEvidence index key of
      Nothing -> pure Nothing
      Just (Evidence token refs Truncated) -> pure (Just (Evidence token refs Truncated))
      Just (Evidence token refs (Available location)) -> do
        value <- ExceptT (Payload.readPayload (instanceScope instanceRef) contract location)
        pure (Just (Evidence token refs (Available value)))
  PublishIndexedFetch (EvidenceSelection instanceRef kind package) contract expected options changes position ->
    lockedIndex instanceRef $ runExceptT $ do
      contents <- indexedBytes instanceRef
      prior <- traverse (ExceptT . decodeIndex) contents
      let current = case prior of
            Just (IndexDocument _ _ _ (EvidenceState (FetchSummary key _ _ _ _ _) _) _) -> Just key
            Nothing -> Nothing
          old = case prior of
            Just (IndexDocument stored selected oldContract (EvidenceState _ values) _)
              | stored == package && selected == kind && contractId oldContract == contractId contract -> values
            _ -> []
      unless (current == expected) (throwE BaseSnapshotConflict)
      staged <- traverse (stageChange instanceRef contract) changes
      next <- liftEither (applyChanges old staged)
      DocumentStamp key at <- ExceptT (Right <$> freshFetchStamp current)
      let latest = FetchSummary (FetchId key) at
            (toInteger (length [() | NewEvidence _ _ <- changes]))
            (toInteger (length [() | UpdatedEvidence _ _ <- changes]))
            (toInteger (length [() | RemovedEvidence _ <- changes])) options
          document = IndexDocument package kind contract (EvidenceState latest next) position
          locations = [location | (_,Evidence _ _ (Available location)) <- next]
          refs = concat [references | PayloadLocation _ _ references <- locations]
      encoded <- ExceptT (encodeIndex document)
      ExceptT (Payload.checkPayloads (instanceScope instanceRef) locations)
      ExceptT (fmap (either (\(FetchError message) -> Left (InvalidEvidence (Text.unpack message))) Right)
        (Blobs.checkBlobsAt instanceRef refs))
      ExceptT $ Right <$> FileSystem.ensureIgnoredDirectory kb cacheLocation
      ExceptT $ Right <$> Document.replaceCurrent encoded
      ExceptT $ Right <$> catchError @Failure.OperationalFailure
        (Payload.reclaimPayloads (instanceScope instanceRef) locations >> Blobs.reclaimBlobsAt instanceRef refs)
        (\_ problem -> raiseFailure (cleanupFailure key problem))
      pure (EvidenceSnapshotRef instanceRef (EvidenceProducer package (contractId contract)) (FetchId key))
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
    instanceScope instanceRef = either error id (directoryScope
      (scopePath kb </> relativeName cacheLocation </> "evidence" </> instancePath instanceRef))
    lockedIndex :: ConnectorInstanceRef -> Eff (DocumentAccess : es) b -> Eff es b
    lockedIndex instanceRef action = case relativePath "index.dhallb" of
      Left message -> raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.InspectEntry "index.dhallb" message))
      Right name -> withLockedDocument (instanceScope instanceRef) name action
    indexedBytes :: ConnectorInstanceRef -> Result (DocumentAccess : es) (Maybe Bytes.ByteString)
    indexedBytes instanceRef = do
      bytes <- readCurrent
      case bytes of
        Just _ -> pure bytes
        Nothing -> do
          name <- either (throwE . InvalidEvidence) pure (relativePath "state.dhall")
          legacy <- ExceptT (Right <$> FileSystem.entryExists (instanceScope instanceRef) name)
          when legacy (throwE (InvalidEvidence "Legacy monolithic evidence storage is unsupported"))
          pure Nothing
    stageChange :: ConnectorInstanceRef -> CheckedContract -> EvidenceChange CheckedValue -> Result (DocumentAccess : es) (EvidenceChange PayloadLocation)
    stageChange instanceRef contract change = case change of
      NewEvidence key value -> NewEvidence key <$> stageEvidence instanceRef contract value
      UpdatedEvidence key value -> UpdatedEvidence key <$> stageEvidence instanceRef contract value
      RemovedEvidence key -> pure (RemovedEvidence key)
      SetEvidencePayload key token value -> SetEvidencePayload key token <$> stagePayload instanceRef contract value
    stageEvidence :: ConnectorInstanceRef -> CheckedContract -> Evidence CheckedValue -> Result (DocumentAccess : es) (Evidence PayloadLocation)
    stageEvidence instanceRef contract (Evidence token refs payload) = Evidence token refs <$> stagePayload instanceRef contract payload
    stagePayload :: ConnectorInstanceRef -> CheckedContract -> EvidencePayload CheckedValue -> Result (DocumentAccess : es) (EvidencePayload PayloadLocation)
    stagePayload _ _ Truncated = pure Truncated
    stagePayload instanceRef contract (Available value) = Available <$> ExceptT (Payload.storePayload (instanceScope instanceRef) contract value)
    locked :: ConnectorInstanceRef -> Eff (DocumentAccess : es) b -> Eff es b
    locked instanceRef action =
      let path = scopePath kb </> relativeName cacheLocation </> "evidence" </> instancePath instanceRef
      in case directoryScope path of
        Left message -> raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.InspectEntry path message))
        Right scope -> case relativePath "state.dhall" of
          Left message -> raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.InspectEntry path message))
          Right name -> withLockedDocument scope name action

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

cleanupFailure :: String -> Failure.OperationalFailure -> Failure.OperationalFailure
cleanupFailure identity problem = case problem of
  Failure.StorageUnavailable (Failure.StorageDiagnostic operation path message) ->
    Failure.StorageUnavailable (Failure.StorageDiagnostic operation path (prefix ++ message))
  _ -> Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.InspectEntry "evidence" (prefix ++ show problem))
  where
    prefix = "Evidence fetch " ++ identity ++ " was published, but reclaiming unreferenced files failed: "
