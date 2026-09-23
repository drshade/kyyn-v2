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
import Kyyn.Domain.Contract (CheckedContract, contractFingerprint, parseContractFingerprint)
import Kyyn.Domain.Evidence
import Kyyn.Domain.KnowledgeBase (cacheLocation)
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.Path (DirectoryScope, scopePath, relativeName, directoryScope)
import Kyyn.Domain.Plugin (pluginNameText, PackageIdentity(..))
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
    traverse (fmap (\(EvidenceHeader _ _ current) -> current) . ExceptT . decodeHeader) bytes
  PublishFetch instanceRef producer contract expected changes -> locked instanceRef $ runExceptT $ do
    bytes <- readCurrent
    header <- traverse (ExceptT . decodeHeader) bytes
    let current = case header of Just (EvidenceHeader _ _ key) -> Just key; Nothing -> Nothing
    unless (current == expected) (throwE BaseSnapshotConflict)
    state <- case (maybe False (matches producer) header,bytes) of
      (True,Just contents) -> ExceptT (decodeState producer contract contents)
      _ -> pure (EvidenceState Nothing [] [])
    let EvidenceState previous values history = state
    (next,markers) <- liftEither (recordChanges instanceRef values changes)
    DocumentStamp key at <- ExceptT (Right <$> Document.freshStamp)
    let identity = FetchId key
        updated = EvidenceState (Just identity) next (history ++ [Fetch identity previous at markers])
    encoded <- ExceptT (encodeState producer contract updated)
    ExceptT $ Right <$> FileSystem.ensureIgnoredDirectory kb cacheLocation
    ExceptT $ Right <$> Document.replaceCurrent encoded
    pure (EvidenceSnapshotRef instanceRef producer identity)
  LoadCurrentEvidence instanceRef producer contract -> locked instanceRef $ runExceptT $ do
    bytes <- readCurrent
    traverse (\contents -> do
      state@(EvidenceState _ values _) <- ExceptT (decodeState producer contract contents)
      snapshot <- snapshotRef instanceRef producer state
      pure (CurrentEvidence snapshot values)) bytes
  ReadFetchHistory instanceRef producer contract -> locked instanceRef $ runExceptT $ do
    state@(EvidenceState _ _ history) <- load producer contract
    snapshot <- snapshotRef instanceRef producer state
    pure (snapshot,map summarizeFetch history)
  ListEvidenceChanges instanceRef producer contract since -> locked instanceRef $ runExceptT $ do
    state <- load producer contract
    snapshot <- snapshotRef instanceRef producer state
    selected <- liftEither (fetchesSince state since)
    pure (snapshot,summarizeChanges selected)
  ClearEvidence instanceRef -> locked instanceRef Document.clearCurrent
  ResolveEvidenceCapture instanceRef selected -> locked instanceRef $ runExceptT $ do
    contents <- readCurrent >>= maybe (throwE NotFetched) pure
    (EvidenceHeader package@(PackageIdentity identity) fingerprint current, history) <- ExceptT (decodeHistory contents)
    unless (not (null identity)) (throwE (InvalidEvidence "Empty evidence producer"))
    contract <- either (throwE . InvalidEvidence) pure (parseContractFingerprint fingerprint)
    liftEither (resolveCapture instanceRef (EvidenceProducer package contract) current history selected)
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
matches (EvidenceProducer producer contract) (EvidenceHeader stored fingerprint _) =
  stored == producer && fingerprint == contractFingerprint contract

snapshotRef :: ConnectorInstanceRef -> EvidenceProducer -> EvidenceState a -> Result es EvidenceSnapshotRef
snapshotRef instanceRef producer (EvidenceState current _ _) =
  maybe (throwE NotFetched) (pure . EvidenceSnapshotRef instanceRef producer) current

load :: (DocumentAccess :> es, DhallHandling :> es)
  => EvidenceProducer -> CheckedContract -> Result es (EvidenceState CheckedValue)
load producer contract = do
  contents <- readCurrent >>= maybe (throwE NotFetched) pure
  ExceptT (decodeState producer contract contents)

readCurrent :: DocumentAccess :> es => Result es (Maybe Bytes.ByteString)
readCurrent = ExceptT (Right <$> Document.readCurrent)

instancePath :: ConnectorInstanceRef -> FilePath
instancePath (ConnectorInstanceRef plugin name) = pluginNameText plugin ++ "-" ++
  concatMap (\byte -> let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits)
    (Bytes.unpack (Text.encodeUtf8 (Text.pack name)))
