-- Real Dhall/filesystem plus recording document persistence: latest-only payloads,
-- ordered deltas, isolation, CAS publication, latest summary, producer changes, clear/refetch
-- and corrupt-data refusal. No plugin invocation or compiler.

{-# LANGUAGE DataKinds, GADTs, OverloadedStrings #-}
module Main (main) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=))
import qualified Data.ByteString.Char8 as Bytes
import Data.Either (isLeft)
import qualified Data.Text as Text
import Data.Time.Clock (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Effectful (Eff, IOE, runEff, runPureEff, (:>), UnliftStrategy(..))
import Effectful.Dispatch.Dynamic (interpret, localLiftUnlift)
import qualified Effectful.State.Static.Local as State
import Kyyn.Domain.Contract
import Kyyn.Domain.Blob (BlobRef(..), blobValue, sdkBlobRefType)
import Kyyn.Domain.DataType (DataType(..), Shape(..))
import Kyyn.Domain.Evidence
import Kyyn.Domain.Path (DirectoryScope, directoryScope)
import Kyyn.Domain.Plugin (pluginName, PackageIdentity(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling(..))
import Kyyn.Porcelain.Capability.EvidenceStore
import qualified Kyyn.Porcelain.Capability.EvidenceInspection as Inspection
import Kyyn.Porcelain.Interpreter.EvidenceInspection (runEvidenceInspection)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem(..))
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence(..), DocumentAccess(..), DocumentStamp(..))
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Plumbing.Interpreter.BlobStorage (runBlobStorageIO)
import Kyyn.Plumbing.Capability.BlobStorage (BlobStorage(..))
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Protocol.EvidencePersistence
import System.Directory (createDirectory, createDirectoryIfMissing, removeDirectory, doesFileExist, doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

contract :: CheckedContract
contract = either (error . show) id (checkContract StringType (SchemaMetadata [] [] []))

producer :: EvidenceProducer
producer = EvidenceProducer (PackageIdentity "package-contents-one") (contractId contract)

instanceA, instanceB :: ConnectorInstanceRef
instanceA = ConnectorInstanceRef (either error id (pluginName "folder")) "sales"
instanceB = ConnectorInstanceRef (either error id (pluginName "folder")) "support"

itemA, itemB :: EvidenceId
itemA = EvidenceId "a.txt"
itemB = EvidenceId "b.txt"

value :: String -> Evidence CheckedValue
value name = Evidence (EvidenceFingerprint (Text.pack name)) [Text.pack ("/source/" ++ name)] (Available (CheckedValue (contractId contract) (String (Text.pack ("payload-only-" ++ name)))))

execute :: DirectoryScope -> Eff '[EvidenceStore, BlobStorage, DocumentPersistence, DhallHandling, FileSystem, Failure, IOE] a -> IO a
execute scope action = runEff (runFailure (runFileSystemIO scope (runDhallHandling (runDocumentPersistenceIO $ (runBlobStorageIO scope . runEvidenceStore scope) action)))) >>= right

key :: EvidenceSnapshotRef -> FetchId
key (EvidenceSnapshotRef _ _ identity) = identity

captureContents :: Maybe CurrentEvidence -> Maybe (EvidenceSnapshotRef, [(EvidenceId, Evidence CheckedValue)])
captureContents = fmap (\(CurrentEvidence snapshot values _) -> (snapshot,values))

availabilityProof :: IO ()
availabilityProof = withSystemTempDirectory "kyyn-payload-" $ \directory -> do
  scope <- right (directoryScope directory)
  let publish prior changes = execute scope (publishFetch instanceA producer contract prior Nothing changes) >>= right
      load = execute scope (loadCurrentEvidence instanceA producer contract) >>= right >>= maybe (fail "Missing capture") pure
  first <- publish Nothing [NewEvidence itemA (value "first")]
  second <- publish (Just (key first)) [SetEvidencePayload itemA (EvidenceFingerprint "first") Truncated]
  CurrentEvidence _ items (FetchSummary _ _ added updated removed _) <- load
  assert "truncation counted as upstream change" ((added,updated,removed) == (0,0,0))
  assert "publication lost truncated item" (items == [(itemA,Evidence (EvidenceFingerprint "first") ["/source/first"] Truncated)])
  let Evidence _ _ payload = value "first"
  _ <- publish (Just (key second)) [SetEvidencePayload itemA (EvidenceFingerprint "first") payload]
  CurrentEvidence _ restored _ <- load
  assert "publication failed to restore payload" (restored == [(itemA,value "first")])

main :: IO ()
main = do
  recordingProof
  positionProof
  availabilityProof
  blobPublicationProof
  let first = [NewEvidence itemA (value "old"),NewEvidence itemB (value "removed")]
      second = [UpdatedEvidence itemA (value "new"),RemovedEvidence itemB]
      summary = FetchSummary (FetchId "one") "2026-09-11T00:00:00Z" 2 0 0 Nothing
  initial <- right (applyChanges [] first)
  assert "duplicate new ID accepted" (isLeft (applyChanges initial [NewEvidence itemA (value "bad")]))
  assert "missing update accepted" (isLeft (applyChanges [] second))
  assert "missing removal accepted" (isLeft (applyChanges [] [RemovedEvidence itemB]))
  assert "empty ID accepted" (isLeft (applyChanges [] [NewEvidence (EvidenceId "") (value "bad")]))
  assert "empty fingerprint accepted" (isLeft (applyChanges [] [NewEvidence itemA (value "")]))
  assert "same-fingerprint update accepted" (case applyChanges initial [UpdatedEvidence itemA (value "old")] of
    Left (InvalidDelta _) -> True; _ -> False)
  let sameTokenDifferentPayload = Evidence (EvidenceFingerprint "old") []
        (Available (CheckedValue (contractId contract) (String "different")))
  assert "same-fingerprint update accepted because payload differed"
    (isLeft (applyChanges initial [UpdatedEvidence itemA sameTokenDifferentPayload]))
  truncated <- right (applyChanges initial [SetEvidencePayload itemA (EvidenceFingerprint "old") Truncated])
  assert "truncation lost metadata" (lookup itemA truncated == Just (Evidence (EvidenceFingerprint "old") ["/source/old"] Truncated))
  let Evidence _ _ originalPayload = value "old"
  restoredPayload <- right (applyChanges truncated [SetEvidencePayload itemA (EvidenceFingerprint "old") originalPayload])
  assert "restoration changed evidence" (restoredPayload == initial)
  assert "missing payload target accepted" (isLeft (applyChanges [] [SetEvidencePayload itemA (EvidenceFingerprint "old") Truncated]))
  assert "stale payload fingerprint accepted" (isLeft (applyChanges initial [SetEvidencePayload itemA (EvidenceFingerprint "wrong") Truncated]))
  newTruncated <- right (applyChanges [] [NewEvidence itemA (Evidence (EvidenceFingerprint "first") [] Truncated)])
  removedTruncated <- right (applyChanges newTruncated [RemovedEvidence itemA])
  assert "truncated evidence cannot be removed" (null removedTruncated)
  truncatedBytes <- right (runPureEff (runDhallHandling (encodeState producer contract (EvidenceState summary truncated))))
  truncatedState <- right (runPureEff (runDhallHandling (decodeState producer contract truncatedBytes)))
  assert "Dhall lost truncation" (truncatedState == EvidenceState summary truncated)
  assert "truncation retained payload" (not (Bytes.isInfixOf "payload-only-old" truncatedBytes))
  sequential <- right (applyChanges [] [NewEvidence itemA (value "a"),UpdatedEvidence itemA (value "b"),RemovedEvidence itemA])
  assert "changes not applied in order" (null sequential)
  let state = EvidenceState summary initial
  assert "duplicate stored IDs accepted" (isLeft (validateState (EvidenceState summary (initial ++ initial))))
  assert "invalid summary accepted" (isLeft (validateState (EvidenceState (FetchSummary (FetchId "") "" (-1) 0 0 Nothing) [])))
  bytes <- right (runPureEff (runDhallHandling (encodeState producer contract state)))
  restored <- right (runPureEff (runDhallHandling (decodeState producer contract bytes)))
  assert "Dhall state round trip differs" (state == restored)
  assert "stored evidence is not current-only" (Bytes.isInfixOf "latest" bytes && not (Bytes.isInfixOf "history" bytes))
  assert "Dhall import accepted" (isLeft (runPureEff (runDhallHandling (decodeHeader "./untrusted.dhall"))))
  header <- right (runPureEff (runDhallHandling (decodeHeader bytes)))
  assert "header loses current" (header == EvidenceHeader (PackageIdentity "package-contents-one")
    (contractFingerprint (contractId contract)) (FetchId "one"))
  let wrongProducer = EvidenceProducer (PackageIdentity "different-source") (contractId contract)
      headerOnly = interpret $ \_ request -> case request of
        DecodeValue (Record fields) _ | map fst fields == ["producer","contract","current"] ->
          pure (Right (object ["producer" .= ("package-contents-one" :: String),
            "contract" .= contractFingerprint (contractId contract),"current" .= ("one" :: String)]))
        _ -> error "Producer refusal attempted payload decoding or encoding"
  assert "producer mismatch reached payload decoder"
    (runPureEff (headerOnly (decodeState wrongProducer contract bytes)) == Left ProducerContractChanged)
  withSystemTempDirectory "kyyn-evidence-" $ \directory -> do
    scope <- right (directoryScope directory)
    let run :: Eff '[EvidenceStore, BlobStorage, DocumentPersistence, DhallHandling, FileSystem, Failure, IOE] a -> IO a
        run = execute scope
        load instanceRef owner = run (loadCurrentEvidence instanceRef owner contract) >>= right
        listing instanceRef owner = run (runEvidenceInspection (Inspection.currentEvidence instanceRef owner contract))
        inspect instanceRef owner item = run (runEvidenceInspection (Inspection.readCurrentEvidence instanceRef owner contract item))
        storePath = directory </> ".kyyn/evidence/folder-73616c6573"
        statePath = storePath </> "state.dhall"
    empty <- load instanceA producer
    assert "new store has current evidence" (empty == Nothing)
    absentListing <- listing instanceA producer
    assert "listing unfetched evidence succeeded" (absentListing == Left [evidenceProblemDiagnostic NotFetched])
    absentItem <- inspect instanceA producer itemA
    assert "unfetched inspection became a missing item" (absentItem == Left [evidenceProblemDiagnostic NotFetched])
    let ignorePath = directory </> ".kyyn/.gitignore"
    ignoredBefore <- doesFileExist ignorePath
    assert "read wrote the ignore file" (not ignoredBefore)
    f1 <- run (publishFetch instanceA producer contract Nothing (Just "first-options") first) >>= right
    EvidenceCapture at1 summary1 listedFirst <- listing instanceA producer >>= right
    assert "listing lost first IDs or fingerprints" (at1 == f1 &&
      listedFirst == [(itemA,EvidenceFingerprint "old",Available ()),(itemB,EvidenceFingerprint "removed",Available ())])
    let emptyInstance = ConnectorInstanceRef (either error id (pluginName "folder")) "empty"
    emptyFetch <- run (publishFetch emptyInstance producer contract Nothing Nothing []) >>= right
    EvidenceCapture emptyAt (FetchSummary _ _ adds updates removals _) listedEmpty <- listing emptyInstance producer >>= right
    assert "fetched empty capture refused" (emptyAt == emptyFetch && null listedEmpty && (adds,updates,removals) == (0,0,0))
    ignore <- Bytes.readFile ignorePath
    assert "first publication did not ignore local evidence" (ignore == "*\n")
    Bytes.writeFile ignorePath "*\n# preserve local comment\n"
    independent <- run (publishFetch instanceB producer contract Nothing Nothing [NewEvidence itemA (value "independent")]) >>= right
    let suppliedOptions = Just "{ label = \"scoped\" }"
    f2 <- run (publishFetch instanceA producer contract (Just (key f1)) suppliedOptions second) >>= right
    preservedIgnore <- Bytes.readFile ignorePath
    assert "publication rewrote existing ignore file" (preservedIgnore == "*\n# preserve local comment\n")
    EvidenceCapture at2 summary2@(FetchSummary identity time added updated removed options) listedLatest <- listing instanceA producer >>= right
    assert "listing retained removed item or old fingerprint" (at2 == f2 && listedLatest == [(itemA,EvidenceFingerprint "new",Available ())])
    assert "latest summary lost identity, count or options" (identity == key f2 && (added,updated,removed) == (0,1,1) && options == suppliedOptions && summary2 /= summary1)
    assert "fetch timestamp is not ISO 8601 UTC" (case iso8601ParseM time :: Maybe UTCTime of
      Just _ -> last time == 'Z'; Nothing -> False)
    inspected <- inspect instanceA producer itemA >>= right
    assert "inspection lost latest summary/payload/fingerprint/references" (inspected == (f2,summary2,Just (value "new")))
    absentAfterRemoval <- inspect instanceA producer itemB >>= right
    assert "inspection returned removed payload" (absentAfterRemoval == (f2,summary2,Nothing))
    (otherAt,_,otherItem) <- inspect instanceB producer itemA >>= right
    assert "inspection mixed instances" (otherAt == independent && otherItem == Just (value "independent"))
    other <- load instanceB producer
    latest <- load instanceA producer
    assert "materialized current evidence wrong" (captureContents latest == Just (f2,[(itemA,value "new")]))
    persisted <- Bytes.readFile statePath
    assert "old contents or history remain on disk"
      (not (any (\old -> Bytes.isInfixOf old persisted) ["payload-only-old","payload-only-removed","first-options","history"])
        && Bytes.isInfixOf "payload-only-new" persisted)
    withSystemTempDirectory "kyyn-other-evidence-" $ \otherDirectory -> do
      otherScope <- right (directoryScope otherDirectory)
      otherHead <- execute otherScope (evidenceHead instanceA) >>= right
      assert "same instance leaked into another KB" (otherHead == Nothing)
    stale <- run (publishFetch instanceA producer contract (Just (key f1)) Nothing [])
    assert "stale base accepted" (stale == Left BaseSnapshotConflict)
    wrong <- run (publishFetch instanceA producer contract (Just (key f2)) Nothing [NewEvidence itemA (value "bad")])
    assert "invalid batch accepted" (isLeft wrong)
    invalidPayload <- run (publishFetch instanceA producer contract (Just (key f2)) Nothing
      [UpdatedEvidence itemA (Evidence (EvidenceFingerprint "invalid-payload") [] (Available (CheckedValue (contractId contract) (Bool True))))])
    assert "forged checked-value shape accepted" (isLeft invalidPayload)
    let boolContract = either (error . show) id (checkContract BoolType (SchemaMetadata [] [] []))
    wrongContract <- run (loadCurrentEvidence instanceA producer boolContract)
    assert "evidence decoded under wrong contract" (wrongContract == Left ProducerContractChanged)
    tip <- run (evidenceHead instanceA) >>= right
    assert "refusal changed head" (tip == Just (key f2))
    (left,rightResult) <- concurrently
      (run (publishFetch instanceA producer contract (Just (key f2)) Nothing []))
      (run (publishFetch instanceA producer contract (Just (key f2)) Nothing []))
    f3 <- case (left,rightResult) of
      (Right result,Left BaseSnapshotConflict) -> pure result
      (Left BaseSnapshotConflict,Right result) -> pure result
      _ -> fail "concurrent writers did not produce exactly one publication"
    let changedProducer = EvidenceProducer (PackageIdentity "package-contents-two") (contractId contract)
    incompatible <- run (loadCurrentEvidence instanceA changedProducer contract)
    assert "same-schema producer change accepted" (incompatible == Left ProducerContractChanged)
    incompatibleListing <- listing instanceA changedProducer
    assert "listing swallowed producer refusal" (incompatibleListing == Left [evidenceProblemDiagnostic ProducerContractChanged])
    failedReset <- run (publishFetch instanceA changedProducer contract (Just (key f3)) Nothing [RemovedEvidence itemA])
    assert "invalid new-producer batch accepted" (isLeft failedReset)
    retained <- load instanceA producer
    assert "failed producer refetch changed evidence" (captureContents retained == Just (f3,[(itemA,value "new")]))
    _ <- run (publishFetch instanceA changedProducer contract (Just (key f3)) Nothing [NewEvidence itemA (value "refetched")]) >>= right
    oldProducer <- run (loadCurrentEvidence instanceA producer contract)
    assert "old producer reinterpreted" (oldProducer == Left ProducerContractChanged)
    replaced <- Bytes.readFile statePath
    assert "producer replacement retained prior contents" (not (Bytes.isInfixOf "payload-only-new" replaced))
    entries <- listDirectory storePath
    assert "producer replacement retained extra documents" (entries == ["state.dhall"])
    existed <- run (clearEvidence instanceA)
    assert "clearing present evidence reported no cache" existed
    remaining <- doesDirectoryExist storePath
    assert "clear retained the instance cache" (not remaining)
    absent <- load instanceA changedProducer
    otherStill <- load instanceB producer
    assert "clear failed or crossed instance boundary" (absent == Nothing && otherStill == other)
    absentClear <- run (clearEvidence instanceA)
    assert "clearing absent evidence reported a cache" (not absentClear)
    fresh <- run (publishFetch instanceA changedProducer contract Nothing Nothing []) >>= right
    emptyCapture <- load instanceA changedProducer
    assert "empty capture confused with not fetched" (captureContents emptyCapture == Just (fresh,[]))
    Bytes.writeFile statePath "{ malformed = True }"
    bad <- run (loadCurrentEvidence instanceA changedProducer contract)
    assert "malformed evidence became absent" (case bad of Left (InvalidEvidence _) -> True; _ -> False)
    badFetch <- run (publishFetch instanceA changedProducer contract (Just (key fresh)) Nothing [])
    assert "fetch silently replaced unreadable data" (isLeft badFetch)
    _ <- run (clearEvidence instanceA)
    _ <- load instanceA changedProducer
    createDirectory storePath
    createDirectory statePath
    failedRead <- runEff (runFailure (runFileSystemIO scope (runDhallHandling (runDocumentPersistenceIO $ (runBlobStorageIO scope . runEvidenceStore scope) (evidenceHead instanceA)))))
    assert "storage error became absent evidence" (isLeft failedRead)
    removeDirectory statePath
    reopened <- run (evidenceHead instanceA) >>= right
    assert "operational failure left store locked" (reopened == Nothing)
  putStrLn "Evidence store: current payloads, latest summary, Dhall, producer reset, clear and concurrent publication passed."

positionProof :: IO ()
positionProof = withSystemTempDirectory "kyyn-position-" $ \directory -> do
  scope <- right (directoryScope directory)
  let run :: Eff '[EvidenceStore, BlobStorage, DocumentPersistence, DhallHandling, FileSystem, Failure, IOE] a -> IO a
      run = execute scope
      cursor label = CheckedValue (contractId contract) (String label)
      begin owner = run (beginFetch instanceA owner contract (Just contract)) >>= right
      publish owner base changes label = run (publishFetchWithPosition instanceA owner contract base Nothing changes
        (Just (contract,cursor label)))
      path = directory </> ".kyyn/evidence/folder-73616c6573/state.dhall"
  FetchBaseline started base prior position <- begin producer
  assert "new acquisition has prior state" (base == Nothing && prior == Nothing && position == Nothing)
  assert "invocation time is not UTC" (case iso8601ParseM started :: Maybe UTCTime of
    Just _ -> last started == 'Z'; Nothing -> False)
  first <- publish producer Nothing [NewEvidence itemA (value "initial")] "cursor-one" >>= right
  FetchBaseline _ firstBase firstCapture firstPosition <- begin producer
  assert "position and capture did not reload together" (firstBase == Just (key first) &&
    captureContents firstCapture == Just (first,[(itemA,value "initial")]) && firstPosition == Just (cursor "cursor-one"))
  second <- publish producer firstBase [] "cursor-two" >>= right
  FetchBaseline _ secondBase _ secondPosition <- begin producer
  assert "empty batch did not advance position" (secondBase == Just (key second) && secondPosition == Just (cursor "cursor-two"))
  before <- Bytes.readFile path
  conflict <- publish producer firstBase [] "stale-cursor"
  assert "stale position published" (conflict == Left BaseSnapshotConflict)
  invalid <- publish producer secondBase [RemovedEvidence itemB] "invalid-cursor"
  assert "invalid delta advanced position" (isLeft invalid)
  wrong <- run (publishFetchWithPosition instanceA producer contract secondBase Nothing []
    (Just (contract,CheckedValue (contractId contract) (Bool True))))
  assert "incorrect position shape accepted" (isLeft wrong)
  after <- Bytes.readFile path
  assert "failed publication changed stored bytes" (before == after)
  let replacement = EvidenceProducer (PackageIdentity "replacement") (contractId contract)
  FetchBaseline _ replacementBase replacementPrior replacementPosition <- begin replacement
  assert "new producer inherited old state" (replacementBase == secondBase && replacementPrior == Nothing && replacementPosition == Nothing)
  failed <- publish replacement replacementBase [RemovedEvidence itemA] "replacement-position"
  assert "invalid replacement accepted" (isLeft failed)
  retained <- Bytes.readFile path
  assert "failed replacement altered old capture" (retained == before)
  new <- publish replacement replacementBase [] "replacement-position" >>= right
  FetchBaseline _ newBase newCapture newPosition <- begin replacement
  assert "replacement did not reset capture and position" (newBase == Just (key new) &&
    captureContents newCapture == Just (new,[]) && newPosition == Just (cursor "replacement-position"))
  old <- run (loadCurrentEvidence instanceA producer contract)
  assert "old producer read replacement capture" (old == Left ProducerContractChanged)
  _ <- run (clearEvidence instanceA)
  FetchBaseline _ clearedBase clearedCapture clearedPosition <- begin replacement
  assert "clear retained position" (clearedBase == Nothing && clearedCapture == Nothing && clearedPosition == Nothing)

type Recording = (Maybe Bytes.ByteString,[String])

recordDocuments :: State.State Recording :> es => Eff (DocumentPersistence : es) a -> Eff es a
recordDocuments = interpret $ \env (WithLockedDocument _ action) ->
  localLiftUnlift env SeqUnlift $ \liftLocal unlift ->
    unlift (interpret (\_ operation -> liftLocal (recordDocument operation)) action)

recordDocument :: State.State Recording :> es => DocumentAccess m a -> Eff es a
recordDocument operation = do
  (document,trace) <- State.get @Recording
  case operation of
    ReadCurrent -> State.put (document,trace ++ ["read"]) >> pure document
    ReplaceCurrent bytes -> State.put (Just bytes,trace ++ ["replace"])
    FreshStamp -> do
      State.put (document,trace ++ ["stamp"])
      let identity = if length (filter (== "stamp") trace) < 2 then "00000001" else "00000002"
      pure (DocumentStamp identity "2026-09-14T00:00:00Z")
    _ -> error "Unexpected persistence operation in semantic publication proof"

recordingProof :: IO ()
recordingProof = do
  let scope = either error id (directoryScope "/recording-kb")
      files = interpret $ \_ operation -> case operation of
        ReadOptionalBytes _ _ -> pure (Just "*")
        _ -> error "Semantic publication requested unexpected filesystem work"
      (result,(_,trace)) = runPureEff . State.runState ((Nothing,[]) :: Recording) . runFailure . files
        . runDhallHandling . recordDocuments . noBlobs . runEvidenceStore scope $ do
          first <- publishFetch instanceA producer contract Nothing Nothing [NewEvidence itemA (value "recorded")]
          conflict <- publishFetch instanceA producer contract Nothing Nothing []
          second <- publishFetch instanceA producer contract (Just (FetchId "00000001")) Nothing []
          pure (first,conflict,second)
  (first,conflict,second) <- right result
  _ <- right first
  assert "recorded semantic store lost CAS refusal" (conflict == Left BaseSnapshotConflict)
  assert "collision was not redrawn" (second == Right (EvidenceSnapshotRef instanceA producer (FetchId "00000002")))
  assert "conflict wrote or collision reused an ID"
    (trace == ["read","stamp","replace","read","read","stamp","stamp","replace"])

blobPublicationProof :: IO ()
blobPublicationProof = withSystemTempDirectory "kyyn-blob-publication-" $ \directory -> do
  scope <- right (directoryScope directory)
  payload <- right (checkContract sdkBlobRefType (SchemaMetadata [] [] []))
  let owner = EvidenceProducer (PackageIdentity "blob-fixture") (contractId payload)
      ref = BlobRef "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" 0 "application/test" Nothing
      blobDirectory = directory </> ".kyyn/evidence" </> instancePath instanceA </> "blobs"
      blobPath = blobDirectory </> "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      item = Evidence (EvidenceFingerprint "same") [] (Available (CheckedValue (contractId payload) (blobValue ref)))
      publish base changes = execute scope (publishFetch instanceA owner payload base Nothing changes)
  missing <- publish Nothing [NewEvidence itemA item]
  assert "dangling blob published" (isLeft missing)
  assert "failed blob publication advanced head" . (== Right Nothing) =<< execute scope (evidenceHead instanceA)
  createDirectoryIfMissing True blobDirectory
  Bytes.writeFile blobPath ""
  first <- publish Nothing [NewEvidence itemA item,NewEvidence itemB item] >>= right
  execute scope (discardFetchBlobs instanceA Nothing [ref])
  assert "changed-head cleanup deleted published bytes" =<< doesFileExist blobPath
  second <- publish (Just (key first)) [SetEvidencePayload itemA (EvidenceFingerprint "same") Truncated] >>= right
  assert "truncating one use deleted shared blob" =<< doesFileExist blobPath
  _ <- publish (Just (key second)) [SetEvidencePayload itemB (EvidenceFingerprint "same") Truncated] >>= right
  assert "truncated payload retained bytes" . not =<< doesFileExist blobPath

noBlobs :: Eff (BlobStorage : es) a -> Eff es a
noBlobs = interpret $ \_ operation -> case operation of
  CheckBlobsAt _ [] -> pure (Right ())
  ReclaimBlobsAt _ [] -> pure ()
  _ -> error "Non-blob fixture requested blob IO"
