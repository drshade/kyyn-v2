module Kyyn.Porcelain.Protocol.EvidencePayload
  ( storePayload, readPayload, checkPayloads, reclaimPayloads ) where

import Control.Monad (forM_, unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.ByteString as Bytes
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Blob (blobReferences)
import Kyyn.Domain.Contract (CheckedContract, contractShape, contractId, rootType)
import Kyyn.Domain.Evidence (EvidenceProblem(..))
import Kyyn.Domain.EvidenceIndex (PayloadLocation(..), payloadLocation)
import Kyyn.Domain.Path (DirectoryScope, RelativePath, relativePath, directoryScope, scopePath, relativeName)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import qualified Kyyn.Domain.Failure as Failure
import qualified Kyyn.Plumbing.Capability.FileSystem as Files
import System.FilePath ((</>))

storePayload :: (FileSystem :> es, DhallHandling :> es)
  => DirectoryScope -> CheckedContract -> CheckedValue -> Eff es (Either EvidenceProblem PayloadLocation)
storePayload scope contract (CheckedValue identity value) = runExceptT $ do
  unless (identity == contractId contract) (throwE ProducerContractChanged)
  source <- ExceptT (fmap (either (Left . InvalidEvidence . show) Right) (encodeValue (contractShape contract) value))
  refs <- either (throwE . InvalidEvidence) pure (blobReferences (rootType contract) value)
  let bytes = Text.encodeUtf8 source
      location@(PayloadLocation _ size _) = payloadLocation bytes refs
  path <- either throwE pure (payloadPath location)
  current <- ExceptT (Right <$> Files.fileSize scope path)
  case current of
    Just existing | existing /= size -> throwE (InvalidEvidence "Stored payload size does not match its content address")
                  | otherwise -> pure ()
    Nothing -> ExceptT (Right <$> Files.replaceBytes scope path bytes)
  pure location

readPayload :: (FileSystem :> es, DhallHandling :> es)
  => DirectoryScope -> CheckedContract -> PayloadLocation -> Eff es (Either EvidenceProblem CheckedValue)
readPayload scope contract location@(PayloadLocation expectedHash size _) = runExceptT $ do
  path <- either throwE pure (payloadPath location)
  bytes <- ExceptT (Right <$> Files.readOptionalBytes scope path) >>= maybe
    (throwE (InvalidEvidence "Referenced evidence payload is missing")) pure
  unless (toInteger (Bytes.length bytes) == size) (throwE (InvalidEvidence "Evidence payload byte count changed"))
  let PayloadLocation actualHash _ _ = payloadLocation bytes []
  unless (actualHash == expectedHash) (throwE (InvalidEvidence "Evidence payload content hash changed"))
  source <- either (throwE . InvalidEvidence . show) pure (Text.decodeUtf8' bytes)
  value <- ExceptT (fmap (either (Left . InvalidEvidence . show) Right) (decodeValue (contractShape contract) source))
  pure (CheckedValue (contractId contract) value)

checkPayloads :: FileSystem :> es => DirectoryScope -> [PayloadLocation] -> Eff es (Either EvidenceProblem ())
checkPayloads scope locations = runExceptT $ forM_ locations $ \location@(PayloadLocation _ expected _) -> do
  path <- either throwE pure (payloadPath location)
  actual <- ExceptT (Right <$> Files.fileSize scope path)
  unless (actual == Just expected) (throwE (InvalidEvidence "Referenced evidence payload is missing or incomplete"))

reclaimPayloads :: (FileSystem :> es, Failure :> es) => DirectoryScope -> [PayloadLocation] -> Eff es ()
reclaimPayloads scope locations = do
  let path = scopePath scope </> "payloads"
      retained = Set.fromList [Text.unpack hash ++ ".dhall" | PayloadLocation hash _ _ <- locations]
  directory <- either (raiseFailure . Failure.StorageUnavailable . Failure.StorageDiagnostic Failure.ListDirectory path)
    pure (directoryScope path)
  names <- Files.listDirectory directory
  forM_ (maybe [] id names) $ \name ->
    unless (relativeName name `Set.member` retained) (Files.removeFile directory name)

payloadPath :: PayloadLocation -> Either EvidenceProblem RelativePath
payloadPath (PayloadLocation hash _ _) = either (Left . InvalidEvidence) Right
  (relativePath ("payloads/" ++ Text.unpack hash ++ ".dhall"))
