{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module Kyyn.Plumbing.Interpreter.EvidenceStore (runEvidenceStoreIO) where

import Control.Exception (IOException, displayException, try)
import Control.Monad (unless, forM_)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time.Clock (getCurrentTime)
import Data.Word (Word64)
import Numeric (showHex)
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import qualified Effectful.Exception as Exception
import Kyyn.Domain.Contract (CheckedContract, contractFingerprint)
import Kyyn.Domain.Evidence
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.Path (DirectoryScope, scopePath)
import Kyyn.Domain.Plugin (pluginNameText)
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.EvidenceStore
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Protocol.Evidence
import System.Directory (createDirectoryIfMissing, listDirectory, removeFile, renameFile)
import System.FileLock (lockFile, unlockFile, SharedExclusive(..))
import System.FilePath ((</>))
import System.IO (hClose, hSetBinaryMode)
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withTempFile)
import System.Random (randomIO)

runEvidenceStoreIO :: forall es a. (IOE :> es, Failure :> es, DhallHandling :> es)
  => DirectoryScope -> Eff (EvidenceStore : es) a -> Eff es a
runEvidenceStoreIO kb = interpret $ \_ -> \case
  EvidenceHead instanceRef -> locked instanceRef $ \directory -> runExceptT $ do
    bytes <- readCurrent directory
    case bytes of
      Nothing -> pure Nothing
      Just contents -> do
        EvidenceHeader _ _ current _ <- ExceptT (decodeHeader contents)
        pure current
  PublishFetch instanceRef producer contract expected changes -> locked instanceRef $ \directory -> runExceptT $ do
    bytes <- readCurrent directory
    header <- traverse (ExceptT . decodeHeader) bytes
    let current = case header of Just (EvidenceHeader _ _ key _) -> key; Nothing -> Nothing
    unless (current == expected) (throwE BaseSnapshotConflict)
    let same = maybe False (matches producer) header
    state <- case (same,bytes) of
      (True,Just contents) -> ExceptT (decodeState producer contract contents)
      _ -> pure (EvidenceState Nothing [] Nothing [] [])
    let EvidenceState baseline initial previous values history = state
    next <- liftEither (applyChanges values changes)
    identity <- ExceptT $ Right <$> native Failure.CreateUniqueDirectory directory freshId
    at <- ExceptT $ Right . show <$> liftIO getCurrentTime
    let updated = EvidenceState baseline initial (Just identity) next (history ++ [Fetch identity previous at changes])
    encoded <- ExceptT (encodeState producer contract updated)
    case (same,bytes) of
      (False,Just old) -> ExceptT $ Right <$> native Failure.WriteFile directory (archive directory old)
      _ -> pure ()
    ExceptT $ Right <$> native Failure.ReplaceFile directory (replace directory encoded)
    pure (EvidenceSnapshotRef instanceRef producer identity)
  SelectEvidence instanceRef producer selection -> locked instanceRef $ \directory -> runExceptT $ do
    contents <- requireCurrent directory
    header@(EvidenceHeader _ _ current history) <- ExceptT (decodeHeader contents)
    unless (matches producer header) (throwE ProducerContractChanged)
    identity <- case selection of
      CurrentEvidence -> maybe (throwE HistoryUnavailable) pure current
      AtFetch identity | identity `elem` history -> pure identity
                       | otherwise -> throwE HistoryUnavailable
    pure (EvidenceSnapshotRef instanceRef producer identity)
  ReadEvidence snapshot@(EvidenceSnapshotRef instanceRef _ identity) contract key -> locked instanceRef $ \directory -> runExceptT $ do
    state <- load directory snapshot contract
    lookup key <$> liftEither (snapshotAt state identity)
  ReadFetchesBetween snapshot@(EvidenceSnapshotRef instanceRef _ identity) contract base -> locked instanceRef $ \directory -> runExceptT $ do
    state <- load directory snapshot contract
    liftEither (fetchesBetween state identity base)
  ListEvidenceChanges snapshot@(EvidenceSnapshotRef instanceRef _ identity) contract base -> locked instanceRef $ \directory -> runExceptT $ do
    state <- load directory snapshot contract
    selected <- liftEither (fetchesBetween state identity base)
    initial <- maybe (pure []) (liftEither . snapshotAt state) base
    liftEither (summarizeChanges instanceRef initial selected)
  DeleteEvidenceHistory instanceRef producer contract -> locked instanceRef $ \directory -> runExceptT $ do
    contents <- requireCurrent directory
    state <- ExceptT (decodeState producer contract contents)
    let EvidenceState _ _ current values _ = state
    encoded <- ExceptT (encodeState producer contract (EvidenceState current values current values []))
    ExceptT $ Right <$> native Failure.ReplaceFile directory (replace directory encoded)
    ExceptT $ Right <$> native Failure.WriteFile directory (clearArchives directory)
  ClearEvidence instanceRef -> locked instanceRef $ \directory ->
    native Failure.WriteFile directory (removeOptional (directory </> "state.dhall") >> clearArchives directory)
  where
    locked :: ConnectorInstanceRef -> (FilePath -> Eff es b) -> Eff es b
    locked instanceRef action = do
      let root = scopePath kb </> ".kyyn" </> "evidence"
          directory = root </> instancePath instanceRef
      native Failure.EnsureDirectory directory $ do
        createDirectoryIfMissing True directory
        Bytes.writeFile (root </> ".gitignore") (Char8.pack "*\n")
      Exception.bracket
        (native Failure.InspectEntry directory (lockFile (directory </> "store.lock") Exclusive))
        (native Failure.InspectEntry directory . unlockFile)
        (const (action directory))

type Result es = ExceptT EvidenceProblem (Eff es)

liftEither :: Either EvidenceProblem a -> Result es a
liftEither = either throwE pure

matches :: EvidenceProducer -> EvidenceHeader -> Bool
matches (EvidenceProducer producer contract) (EvidenceHeader stored fingerprint _ _) =
  stored == producer && fingerprint == contractFingerprint contract

load :: (IOE :> es, Failure :> es, DhallHandling :> es)
  => FilePath -> EvidenceSnapshotRef -> CheckedContract -> Result es (EvidenceState CheckedValue)
load directory (EvidenceSnapshotRef _ producer _) contract = do
  contents <- requireCurrent directory
  ExceptT (decodeState producer contract contents)

readCurrent :: (IOE :> es, Failure :> es) => FilePath -> Result es (Maybe Bytes.ByteString)
readCurrent directory = ExceptT $ Right <$> native Failure.ReadFile directory (do
  result <- try (Bytes.readFile (directory </> "state.dhall"))
  case result of
    Right bytes -> pure (Just bytes)
    Left err | isDoesNotExistError err -> pure Nothing
             | otherwise -> ioError err)

requireCurrent :: (IOE :> es, Failure :> es) => FilePath -> Result es Bytes.ByteString
requireCurrent directory = readCurrent directory >>= maybe (throwE HistoryUnavailable) pure

instancePath :: ConnectorInstanceRef -> FilePath
instancePath (ConnectorInstanceRef plugin name) = pluginNameText plugin ++ "-" ++
  concatMap (\byte -> let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits)
    (Bytes.unpack (Text.encodeUtf8 (Text.pack name)))

freshId :: IO FetchId
freshId = do
  first <- randomIO :: IO Word64
  second <- randomIO :: IO Word64
  pure (FetchId (showHex first "-" ++ showHex second ""))

replace :: FilePath -> Bytes.ByteString -> IO ()
replace directory bytes = withTempFile directory ".pending-" $ \path handle -> do
  hSetBinaryMode handle True
  Bytes.hPut handle bytes
  hClose handle
  renameFile path (directory </> "state.dhall")

archive :: FilePath -> Bytes.ByteString -> IO ()
archive directory bytes = do
  FetchId identity <- freshId
  let archives = directory </> "archives"
  createDirectoryIfMissing True archives
  Bytes.writeFile (archives </> identity ++ ".dhall") bytes

clearArchives :: FilePath -> IO ()
clearArchives directory = do
  let archives = directory </> "archives"
  entries <- try (listDirectory archives)
  case entries of
    Left err | isDoesNotExistError err -> pure ()
             | otherwise -> ioError err
    Right names -> forM_ names (removeFile . (archives </>))

removeOptional :: FilePath -> IO ()
removeOptional path = do
  result <- try (removeFile path)
  case result of
    Left err | isDoesNotExistError err -> pure ()
             | otherwise -> ioError err
    Right () -> pure ()

native :: (IOE :> es, Failure :> es) => Failure.StorageOperation -> FilePath -> IO a -> Eff es a
native operation path action = liftIO action `Exception.catch` \(err :: IOException) ->
  raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic operation path (displayException err)))
