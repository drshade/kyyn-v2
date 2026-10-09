{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore) where

import Control.Monad (unless, when)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.ByteString as Bytes
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (catchError)
import Kyyn.Domain.Contract (CheckedContract, contractId)
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
import Kyyn.Porcelain.Protocol.EvidenceIndex (IndexDocument(..), encodeIndex, decodeIndex, capturedIndex)
import qualified Kyyn.Porcelain.Protocol.EvidencePayload as Payload
import System.FilePath ((</>))

runEvidenceStore :: forall es a. (Blobs.BlobStorage :> es, DocumentPersistence :> es, Failure :> es, DhallHandling :> es, FileSystem.FileSystem :> es)
  => DirectoryScope -> Eff (EvidenceStore : es) a -> Eff es a
runEvidenceStore kb = interpret $ \_ -> \case
  BeginFetch (EvidenceSelection instanceRef kind package) contract positionContract -> lockedIndex instanceRef $ runExceptT $ do
    DocumentStamp _ started <- ExceptT (Right <$> Document.freshStamp)
    bytes <- ExceptT (Right <$> readCurrent)
    document <- traverse (ExceptT . decodeIndex) bytes
    let base = case document of
          Just (IndexDocument _ _ _ (EvidenceState (FetchSummary key _ _ _ _ _) _) _) -> Just key
          Nothing -> Nothing
    case document of
      Just selected@(IndexDocument stored connector payload _ position)
        | stored == package && connector == kind && contractId payload == contractId contract
        , fmap (contractId . fst) position == fmap contractId positionContract ->
          pure (FetchBaseline started base (Just (capturedIndex instanceRef selected)) (snd <$> position))
      _ -> pure (FetchBaseline started base Nothing Nothing)
  OpenCurrentEvidence (EvidenceSelection instanceRef kind package) -> lockedIndex instanceRef $ runExceptT $ do
    bytes <- ExceptT (Right <$> readCurrent)
    traverse (\contents -> do
      document@(IndexDocument stored selected _ _ _) <- ExceptT (decodeIndex contents)
      unless (stored == package && selected == kind) (throwE ProducerContractChanged)
      pure (capturedIndex instanceRef document)) bytes
  ReadCapturedEvidence index@(EvidenceIndex (EvidenceSnapshotRef instanceRef _ _) _ contract _) key -> runExceptT $
    case indexedEvidence index key of
      Nothing -> pure Nothing
      Just (Evidence token refs Truncated) -> pure (Just (Evidence token refs Truncated))
      Just (Evidence token refs (Available location)) -> do
        scope <- checkedScope instanceRef
        value <- ExceptT (Payload.readPayload scope contract location)
        pure (Just (Evidence token refs (Available value)))
  PublishFetch (EvidenceSelection instanceRef kind package) contract expected options changes position ->
    lockedIndex instanceRef $ runExceptT $ do
      scope <- checkedScope instanceRef
      contents <- ExceptT (Right <$> readCurrent)
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
      ExceptT (Payload.checkPayloads scope locations)
      ExceptT (fmap (either (\(FetchError message) -> Left (InvalidEvidence (Text.unpack message))) Right)
        (Blobs.checkBlobsAt instanceRef refs))
      ExceptT $ Right <$> FileSystem.ensureIgnoredDirectory kb cacheLocation
      ExceptT $ Right <$> Document.replaceCurrent encoded
      ExceptT $ Right <$> catchError @Failure.OperationalFailure
        (Payload.reclaimPayloads scope locations >> Blobs.reclaimBlobsAt instanceRef refs)
        (\_ problem -> raiseFailure (cleanupFailure key problem))
      pure (EvidenceSnapshotRef instanceRef (EvidenceProducer package (contractId contract)) (FetchId key))
  DiscardFetchBlobs instanceRef expected created -> lockedIndex instanceRef $ do
    current <- runExceptT $ do
      bytes <- ExceptT (Right <$> readCurrent)
      document <- traverse (ExceptT . decodeIndex) bytes
      pure (fmap (\(IndexDocument _ _ _ (EvidenceState (FetchSummary key _ _ _ _ _) _) _) -> key) document)
    when (current == Right expected) (Blobs.discardBlobsAt instanceRef created)
  EvidenceHead instanceRef -> lockedIndex instanceRef $ runExceptT $ do
    bytes <- ExceptT (Right <$> readCurrent)
    traverse (fmap (\(IndexDocument _ _ _ (EvidenceState (FetchSummary key _ _ _ _ _) _) _) -> key) . ExceptT . decodeIndex) bytes
  ClearEvidence instanceRef -> lockedIndex instanceRef Document.clearCurrent
  where
    instanceScope instanceRef = directoryScope
      (scopePath kb </> relativeName cacheLocation </> "evidence" </> instancePath instanceRef)
    checkedScope :: ConnectorInstanceRef -> Result effects DirectoryScope
    checkedScope = either (throwE . InvalidEvidence) pure . instanceScope
    lockedIndex :: ConnectorInstanceRef -> Eff (DocumentAccess : es) b -> Eff es b
    lockedIndex instanceRef action = case (,) <$> instanceScope instanceRef <*> relativePath "index.dhallb" of
      Left message -> raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.InspectEntry "index.dhallb" message))
      Right (scope,name) -> withLockedDocument scope name action
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
    stagePayload instanceRef contract (Available value) = do
      scope <- checkedScope instanceRef
      Available <$> ExceptT (Payload.storePayload scope contract value)

type Result es = ExceptT EvidenceProblem (Eff es)

freshFetchStamp :: DocumentAccess :> es => Maybe FetchId -> Eff es DocumentStamp
freshFetchStamp current = do
  stamp@(DocumentStamp key _) <- Document.freshStamp
  if current == Just (FetchId key) then freshFetchStamp current else pure stamp

liftEither :: Either EvidenceProblem a -> Result es a
liftEither = either throwE pure

readCurrent :: DocumentAccess :> es => Result es (Maybe Bytes.ByteString)
readCurrent = ExceptT (Right <$> Document.readCurrent)

cleanupFailure :: String -> Failure.OperationalFailure -> Failure.OperationalFailure
cleanupFailure identity problem = case problem of
  Failure.StorageUnavailable (Failure.StorageDiagnostic operation path message) ->
    Failure.StorageUnavailable (Failure.StorageDiagnostic operation path (prefix ++ message))
  _ -> Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.InspectEntry "evidence" (prefix ++ show problem))
  where
    prefix = "Evidence fetch " ++ identity ++ " was published, but reclaiming unreferenced files failed: "
