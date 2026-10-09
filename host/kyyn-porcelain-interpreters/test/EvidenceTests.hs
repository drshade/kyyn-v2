-- Real Dhall/filesystem plus recording document persistence: latest-only payloads,
-- ordered deltas, isolation, CAS publication, latest summary, producer changes, clear/refetch
-- and corrupt-data refusal. No plugin invocation or compiler.

{-# LANGUAGE DataKinds, GADTs, OverloadedStrings #-}
module Main (main) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (Value(..))
import qualified Data.ByteString.Char8 as Bytes
import Data.Either (isLeft)
import qualified Data.Text as Text
import Data.Time.Clock (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Effectful (Eff, IOE, runEff, runPureEff, (:>), UnliftStrategy(..))
import Effectful.Dispatch.Dynamic (interpret, localLiftUnlift)
import qualified Effectful.State.Static.Local as State
import Kyyn.Domain.Contract
import Kyyn.Domain.Blob (BlobRef(..), ResolvedBlob(..), blobValue, sdkBlobRefType)
import Kyyn.Domain.DataType (DataType(..))
import Kyyn.Domain.Evidence
import Kyyn.Domain.EvidenceIndex (EvidenceSelection(..), EvidenceIndex(EvidenceIndex), PayloadLocation(..), payloadLocation, indexState)
import Kyyn.Domain.Path (DirectoryScope, directoryScope, relativeName, relativePath)
import Kyyn.Domain.Plugin (pluginName, PackageIdentity(..), ConnectorTypeName(..), ConnectorName(..))
import Kyyn.Domain.FileTree (fileTree)
import Kyyn.Domain.Git (Repository(..), TreePath(..), gitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling(..))
import Kyyn.Porcelain.Capability.EvidenceStore
import Kyyn.Plumbing.Capability.Git (Git(..))
import qualified Kyyn.Porcelain.Capability.EvidenceInspection as Inspection
import Kyyn.Porcelain.Interpreter.EvidenceInspection (runEvidenceInspection)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence(..), DocumentAccess(..), DocumentStamp(..))
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead)
import Kyyn.Porcelain.Capability.PluginRead (resolveCapturedBlobs, loadCapturedInput)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (guestSources, packageIdentity)
import Kyyn.Plumbing.Interpreter.BlobStorage (runBlobStorageIO)
import Kyyn.Plumbing.Capability.BlobStorage (BlobStorage(..))
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import qualified Kyyn.Porcelain.Protocol.EvidenceIndex as Index
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

selectionFor :: ConnectorInstanceRef -> EvidenceProducer -> EvidenceSelection
selectionFor ref (EvidenceProducer package _) = EvidenceSelection ref (ConnectorTypeName "Folder") package

publishFixture :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe FetchId -> Maybe String
  -> [EvidenceChange CheckedValue] -> Eff es (Either EvidenceProblem EvidenceSnapshotRef)
publishFixture ref owner schema base options changes = publishFetchWithPosition ref owner schema base options changes Nothing

publishFetchWithPosition :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe FetchId -> Maybe String
  -> [EvidenceChange CheckedValue] -> Maybe (CheckedContract,CheckedValue) -> Eff es (Either EvidenceProblem EvidenceSnapshotRef)
publishFetchWithPosition ref owner = publishFetch (selectionFor ref owner)

materialize :: EvidenceStore :> es => EvidenceIndex -> Eff es (Either EvidenceProblem CurrentEvidence)
materialize index@(EvidenceIndex snapshot summary _ _) = runExceptT $ do
  let EvidenceState _ entries = indexState index
  values <- mapM (\(ident,_) -> do
    found <- ExceptT (readCapturedEvidence index ident)
    case found of
      Just evidence -> pure (ident,evidence)
      Nothing -> throwE (InvalidEvidence "Test index lost entry")) entries
  pure (CurrentEvidence snapshot values summary)

loadCurrentEvidence :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Eff es (Either EvidenceProblem (Maybe CurrentEvidence))
loadCurrentEvidence ref owner expected = runExceptT $ do
  index <- ExceptT (openCurrentEvidence (selectionFor ref owner))
  traverse (\captured@(EvidenceIndex _ _ schema _) -> do
    unless (contractId expected == contractId schema) (throwE ProducerContractChanged)
    ExceptT (materialize captured)) index

data CurrentEvidence = CurrentEvidence EvidenceSnapshotRef [(EvidenceId,Evidence CheckedValue)] FetchSummary deriving (Eq, Show)
data MaterializedBaseline = MaterializedBaseline String (Maybe FetchId) (Maybe CurrentEvidence) (Maybe CheckedValue)

beginFixture :: EvidenceStore :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> Maybe CheckedContract
  -> Eff es (Either EvidenceProblem MaterializedBaseline)
beginFixture ref owner schema position = runExceptT $ do
  FetchBaseline started base capture cursor <- ExceptT (beginFetch (selectionFor ref owner) schema position)
  values <- traverse (ExceptT . materialize) capture
  pure (MaterializedBaseline started base values cursor)

noGit :: Eff (Git : es) a -> Eff es a
noGit = interpret $ \_ _ -> error "Already selected evidence requested Git"

key :: EvidenceSnapshotRef -> FetchId
key (EvidenceSnapshotRef _ _ identity) = identity

captureContents :: Maybe CurrentEvidence -> Maybe (EvidenceSnapshotRef, [(EvidenceId, Evidence CheckedValue)])
captureContents = fmap (\(CurrentEvidence snapshot values _) -> (snapshot,values))

availabilityProof :: IO ()
availabilityProof = withSystemTempDirectory "kyyn-payload-" $ \directory -> do
  scope <- right (directoryScope directory)
  let publish prior changes = execute scope (publishFixture instanceA producer contract prior Nothing changes) >>= right
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
  selectionProof
  cleanupFailureProof
  selectiveIndexProof
  indexedPublicationProof
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
  sequential <- right (applyChanges [] [NewEvidence itemA (value "a"),UpdatedEvidence itemA (value "b"),RemovedEvidence itemA])
  assert "changes not applied in order" (null sequential)
  assert "duplicate stored IDs accepted" (isLeft (validateState (EvidenceState summary (initial ++ initial))))
  assert "invalid summary accepted" (isLeft (validateState (EvidenceState (FetchSummary (FetchId "") "" (-1) 0 0 Nothing) [])))
  withSystemTempDirectory "kyyn-evidence-" $ \directory -> do
    scope <- right (directoryScope directory)
    let run :: Eff '[EvidenceStore, BlobStorage, DocumentPersistence, DhallHandling, FileSystem, Failure, IOE] a -> IO a
        run = execute scope
        load instanceRef owner = run (loadCurrentEvidence instanceRef owner contract) >>= right
        listing instanceRef owner = run (noGit (runEvidenceInspection (Inspection.currentEvidence (selectionFor instanceRef owner))))
        inspect instanceRef owner item = fmap (fmap (\(at,latestSummary,_,found) -> (at,latestSummary,found)))
          (run (noGit (runEvidenceInspection (Inspection.readCurrentEvidence (selectionFor instanceRef owner) item))))
        storePath = directory </> ".kyyn/evidence/folder-73616c6573"
        statePath = storePath </> "index.dhallb"
    empty <- load instanceA producer
    assert "new store has current evidence" (empty == Nothing)
    absentListing <- listing instanceA producer
    assert "listing unfetched evidence succeeded" (absentListing == Left [evidenceProblemDiagnostic NotFetched])
    absentItem <- inspect instanceA producer itemA
    assert "unfetched inspection became a missing item" (absentItem == Left [evidenceProblemDiagnostic NotFetched])
    let ignorePath = directory </> ".kyyn/.gitignore"
    ignoredBefore <- doesFileExist ignorePath
    assert "read wrote the ignore file" (not ignoredBefore)
    f1 <- run (publishFixture instanceA producer contract Nothing (Just "first-options") first) >>= right
    EvidenceCapture at1 summary1 listedFirst <- listing instanceA producer >>= right
    assert "listing lost first IDs or fingerprints" (at1 == f1 &&
      listedFirst == [(itemA,EvidenceFingerprint "old",Available ()),(itemB,EvidenceFingerprint "removed",Available ())])
    let emptyInstance = ConnectorInstanceRef (either error id (pluginName "folder")) "empty"
    emptyFetch <- run (publishFixture emptyInstance producer contract Nothing Nothing []) >>= right
    EvidenceCapture emptyAt (FetchSummary _ _ adds updates removals _) listedEmpty <- listing emptyInstance producer >>= right
    assert "fetched empty capture refused" (emptyAt == emptyFetch && null listedEmpty && (adds,updates,removals) == (0,0,0))
    ignore <- Bytes.readFile ignorePath
    assert "first publication did not ignore local evidence" (ignore == "*\n")
    Bytes.writeFile ignorePath "*\n# preserve local comment\n"
    independent <- run (publishFixture instanceB producer contract Nothing Nothing [NewEvidence itemA (value "independent")]) >>= right
    let suppliedOptions = Just "{ label = \"scoped\" }"
    f2 <- run (publishFixture instanceA producer contract (Just (key f1)) suppliedOptions second) >>= right
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
        && not (Bytes.isInfixOf "payload-only-new" persisted))
    withSystemTempDirectory "kyyn-other-evidence-" $ \otherDirectory -> do
      otherScope <- right (directoryScope otherDirectory)
      otherHead <- execute otherScope (evidenceHead instanceA) >>= right
      assert "same instance leaked into another KB" (otherHead == Nothing)
    stale <- run (publishFixture instanceA producer contract (Just (key f1)) Nothing [])
    assert "stale base accepted" (stale == Left BaseSnapshotConflict)
    wrong <- run (publishFixture instanceA producer contract (Just (key f2)) Nothing [NewEvidence itemA (value "bad")])
    assert "invalid batch accepted" (isLeft wrong)
    invalidPayload <- run (publishFixture instanceA producer contract (Just (key f2)) Nothing
      [UpdatedEvidence itemA (Evidence (EvidenceFingerprint "invalid-payload") [] (Available (CheckedValue (contractId contract) (Bool True))))])
    assert "forged checked-value shape accepted" (isLeft invalidPayload)
    let boolContract = either (error . show) id (checkContract BoolType (SchemaMetadata [] [] []))
    wrongContract <- run (loadCurrentEvidence instanceA producer boolContract)
    assert "evidence decoded under wrong contract" (wrongContract == Left ProducerContractChanged)
    guestContract <- run (noGuestExecution (runPluginRead (loadCapturedInput (selectionFor instanceA producer) boolContract)))
    assert "guest binding accepted incompatible stored descriptor" (case guestContract of
      Left diagnostics -> "evidence.producer-changed" `Text.isInfixOf` Text.pack (show diagnostics)
      Right _ -> False)
    tip <- run (evidenceHead instanceA) >>= right
    assert "refusal changed head" (tip == Just (key f2))
    (left,rightResult) <- concurrently
      (run (publishFixture instanceA producer contract (Just (key f2)) Nothing []))
      (run (publishFixture instanceA producer contract (Just (key f2)) Nothing []))
    f3 <- case (left,rightResult) of
      (Right result,Left BaseSnapshotConflict) -> pure result
      (Left BaseSnapshotConflict,Right result) -> pure result
      _ -> fail "concurrent writers did not produce exactly one publication"
    let changedProducer = EvidenceProducer (PackageIdentity "package-contents-two") (contractId contract)
    incompatible <- run (loadCurrentEvidence instanceA changedProducer contract)
    assert "same-schema producer change accepted" (incompatible == Left ProducerContractChanged)
    incompatibleListing <- listing instanceA changedProducer
    assert "listing swallowed producer refusal" (incompatibleListing == Left [evidenceProblemDiagnostic ProducerContractChanged])
    failedReset <- run (publishFixture instanceA changedProducer contract (Just (key f3)) Nothing [RemovedEvidence itemA])
    assert "invalid new-producer batch accepted" (isLeft failedReset)
    retained <- load instanceA producer
    assert "failed producer refetch changed evidence" (captureContents retained == Just (f3,[(itemA,value "new")]))
    _ <- run (publishFixture instanceA changedProducer contract (Just (key f3)) Nothing [NewEvidence itemA (value "refetched")]) >>= right
    oldProducer <- run (loadCurrentEvidence instanceA producer contract)
    assert "old producer reinterpreted" (oldProducer == Left ProducerContractChanged)
    replaced <- Bytes.readFile statePath
    assert "producer replacement retained prior contents" (not (Bytes.isInfixOf "payload-only-new" replaced))
    entries <- listDirectory storePath
    assert "producer replacement retained extra documents" (length entries == 2 && all (`elem` entries) ["index.dhallb","payloads"])
    existed <- run (clearEvidence instanceA)
    assert "clearing present evidence reported no cache" existed
    remaining <- doesDirectoryExist storePath
    assert "clear retained the instance cache" (not remaining)
    absent <- load instanceA changedProducer
    otherStill <- load instanceB producer
    assert "clear failed or crossed instance boundary" (absent == Nothing && otherStill == other)
    absentClear <- run (clearEvidence instanceA)
    assert "clearing absent evidence reported a cache" (not absentClear)
    fresh <- run (publishFixture instanceA changedProducer contract Nothing Nothing []) >>= right
    emptyCapture <- load instanceA changedProducer
    assert "empty capture confused with not fetched" (captureContents emptyCapture == Just (fresh,[]))
    Bytes.writeFile statePath "{ malformed = True }"
    bad <- run (loadCurrentEvidence instanceA changedProducer contract)
    assert "malformed evidence became absent" (case bad of Left (InvalidEvidence _) -> True; _ -> False)
    badFetch <- run (publishFixture instanceA changedProducer contract (Just (key fresh)) Nothing [])
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
      begin owner = run (beginFixture instanceA owner contract (Just contract)) >>= right
      publish owner base changes label = run (publishFetchWithPosition instanceA owner contract base Nothing changes
        (Just (contract,cursor label)))
      path = directory </> ".kyyn/evidence/folder-73616c6573/index.dhallb"
  MaterializedBaseline started base prior position <- begin producer
  assert "new acquisition has prior state" (base == Nothing && prior == Nothing && position == Nothing)
  assert "invocation time is not UTC" (case iso8601ParseM started :: Maybe UTCTime of
    Just _ -> last started == 'Z'; Nothing -> False)
  first <- publish producer Nothing [NewEvidence itemA (value "initial")] "cursor-one" >>= right
  MaterializedBaseline _ firstBase firstCapture firstPosition <- begin producer
  assert "position and capture did not reload together" (firstBase == Just (key first) &&
    captureContents firstCapture == Just (first,[(itemA,value "initial")]) && firstPosition == Just (cursor "cursor-one"))
  second <- publish producer firstBase [] "cursor-two" >>= right
  MaterializedBaseline _ secondBase _ secondPosition <- begin producer
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
  MaterializedBaseline _ replacementBase replacementPrior replacementPosition <- begin replacement
  assert "new producer inherited old state" (replacementBase == secondBase && replacementPrior == Nothing && replacementPosition == Nothing)
  failed <- publish replacement replacementBase [RemovedEvidence itemA] "replacement-position"
  assert "invalid replacement accepted" (isLeft failed)
  retained <- Bytes.readFile path
  assert "failed replacement altered old capture" (retained == before)
  new <- publish replacement replacementBase [] "replacement-position" >>= right
  MaterializedBaseline _ newBase newCapture newPosition <- begin replacement
  assert "replacement did not reset capture and position" (newBase == Just (key new) &&
    captureContents newCapture == Just (new,[]) && newPosition == Just (cursor "replacement-position"))
  old <- run (loadCurrentEvidence instanceA producer contract)
  assert "old producer read replacement capture" (old == Left ProducerContractChanged)
  _ <- run (clearEvidence instanceA)
  MaterializedBaseline _ clearedBase clearedCapture clearedPosition <- begin replacement
  assert "clear retained position" (clearedBase == Nothing && clearedCapture == Nothing && clearedPosition == Nothing)

type Recording = (Maybe Bytes.ByteString,[String])

recordDocuments :: State.State Recording :> es => Eff (DocumentPersistence : es) a -> Eff es a
recordDocuments = interpret $ \env (WithLockedDocument _ _ action) ->
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
        EntryExists _ _ -> pure False
        FileSize _ _ -> pure (Just 24)
        ListDirectory _ -> pure (Just [])
        _ -> error "Semantic publication requested unexpected filesystem work"
      (result,(_,trace)) = runPureEff . State.runState ((Nothing,[]) :: Recording) . runFailure . files
        . runDhallHandling . recordDocuments . noBlobs . runEvidenceStore scope $ do
          first <- publishFixture instanceA producer contract Nothing Nothing []
          conflict <- publishFixture instanceA producer contract Nothing Nothing []
          second <- publishFixture instanceA producer contract (Just (FetchId "00000001")) Nothing []
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
      publish base changes = execute scope (publishFixture instanceA owner payload base Nothing changes)
  missing <- publish Nothing [NewEvidence itemA item]
  assert "dangling blob published" (isLeft missing)
  assert "failed blob publication advanced head" . (== Right Nothing) =<< execute scope (evidenceHead instanceA)
  createDirectoryIfMissing True blobDirectory
  Bytes.writeFile blobPath ""
  first <- publish Nothing [NewEvidence itemA item,NewEvidence itemB item] >>= right
  captured <- execute scope (openCurrentEvidence (selectionFor instanceA owner)) >>= right >>= maybe (fail "No blob capture") pure
  let resolve contexts output = execute scope (noGuestExecution (runPluginRead (resolveCapturedBlobs contexts payload output)))
  resolved <- resolve [captured] (blobValue ref) >>= right
  assert "blob surface lost originating path" (resolved == [ResolvedBlob ref blobPath])
  assert "forged result resolved without capture" . isLeft =<< resolve [] (blobValue ref)
  execute scope (discardFetchBlobs instanceA Nothing [ref])
  assert "changed-head cleanup deleted published bytes" =<< doesFileExist blobPath
  second <- publish (Just (key first)) [SetEvidencePayload itemA (EvidenceFingerprint "same") Truncated] >>= right
  assert "truncating one use deleted shared blob" =<< doesFileExist blobPath
  _ <- publish (Just (key second)) [SetEvidencePayload itemB (EvidenceFingerprint "same") Truncated] >>= right
  assert "truncated payload retained bytes" . not =<< doesFileExist blobPath
  assert "old capture resolved reclaimed bytes" . isLeft =<< resolve [captured] (blobValue ref)

noGuestExecution :: Eff (GuestExecution : es) a -> Eff es a
noGuestExecution = interpret $ \_ _ -> error "Blob resolution invoked a guest"

noBlobs :: Eff (BlobStorage : es) a -> Eff es a
noBlobs = interpret $ \_ operation -> case operation of
  CheckBlobsAt _ [] -> pure (Right ())
  ReclaimBlobsAt _ [] -> pure ()
  _ -> error "Non-blob fixture requested blob IO"

selection :: EvidenceSelection
selection = EvidenceSelection instanceA (ConnectorTypeName "Folder") (PackageIdentity "package-contents-one")

selectiveIndexProof :: IO ()
selectiveIndexProof = do
  let payload = "\"selected payload\""
      location@(PayloadLocation hash _ _) = payloadLocation payload []
      wanted = "payloads/" ++ Text.unpack hash ++ ".dhall"
      summary = FetchSummary (FetchId "indexed") "2026-10-08T00:00:00Z" 3 0 0 Nothing
      document = Index.IndexDocument (PackageIdentity "package-contents-one") (ConnectorTypeName "Folder") contract
        (EvidenceState summary
          [(itemA,Evidence (EvidenceFingerprint "one") [] (Available location))
          ,(itemB,Evidence (EvidenceFingerprint "two") [] (Available (PayloadLocation (Text.replicate 64 "b") 900 [])))
          ,(EvidenceId "truncated",Evidence (EvidenceFingerprint "three") [] Truncated)]) Nothing
      scope = either error id (directoryScope "/recording-kb")
      files = interpret $ \_ operation -> case operation of
        ReadOptionalBytes _ path -> do
          State.modify @Recording (\(stored,trace) -> (stored,trace ++ [relativeName path]))
          pure (Just (if relativeName path == wanted then payload else "corrupt unrelated payload"))
        _ -> error "Index inspection requested unexpected filesystem work"
  bytes <- right (runPureEff (runDhallHandling (Index.encodeIndex document)))
  let (result,(_,trace)) = runPureEff . State.runState ((Just bytes,[]) :: Recording) . runFailure . files
        . runDhallHandling . recordDocuments . noBlobs . runEvidenceStore scope $ do
          opened <- openCurrentEvidence selection
          case opened of
            Right (Just index) -> do
              selected <- readCapturedEvidence index itemA
              missing <- readCapturedEvidence index (EvidenceId "absent")
              truncated <- readCapturedEvidence index (EvidenceId "truncated")
              pure (selected,missing,truncated)
            _ -> error "Cannot open test index"
  (selected,missing,truncated) <- right result
  assert "selected payload did not decode" (selected == Right (Just (Evidence (EvidenceFingerprint "one") []
    (Available (CheckedValue (contractId contract) (String "selected payload"))))))
  assert "missing evidence not absent" (missing == Right Nothing)
  assert "truncated evidence lost metadata" (truncated == Right (Just (Evidence (EvidenceFingerprint "three") [] Truncated)))
  assert "index read more than selected payload" (trace == ["read",wanted])

indexedPublicationProof :: IO ()
indexedPublicationProof = withSystemTempDirectory "kyyn-index-publication-" $ \directory -> do
  scope <- right (directoryScope directory)
  let publish base changes = execute scope (publishFetch selection contract base Nothing changes Nothing)
      open = execute scope (openCurrentEvidence selection) >>= right >>= maybe (fail "Missing index") pure
      payloadDirectory = directory </> ".kyyn/evidence" </> instancePath instanceA </> "payloads"
  first <- publish Nothing [NewEvidence itemA (value "first"),NewEvidence itemB (value "second")] >>= right
  conflict <- publish Nothing [UpdatedEvidence itemA (value "conflict")]
  assert "indexed publication ignored expected fetch" (conflict == Left BaseSnapshotConflict)
  names <- listDirectory payloadDirectory
  assert "failed CAS wrote payload" (length names == 2)
  second <- publish (Just (key first)) [SetEvidencePayload itemB (EvidenceFingerprint "second") Truncated] >>= right
  remaining <- listDirectory payloadDirectory
  assert "truncation did not reclaim payload" (length remaining == 1)
  index <- open
  selected <- execute scope (readCapturedEvidence index itemA)
  assert "unchanged payload not reused" (selected == Right (Just (value "first")))
  selectedName <- case remaining of
    [name] -> pure name
    _ -> fail "Expected one retained payload"
  let selectedPath = payloadDirectory </> selectedName
  original <- Bytes.readFile selectedPath
  Bytes.writeFile selectedPath (Bytes.replicate (Bytes.length original) 'x')
  corrupt <- execute scope (readCapturedEvidence index itemA)
  assert "same-size payload corruption was accepted" (case corrupt of
    Left (InvalidEvidence message) -> "hash" `Text.isInfixOf` Text.pack message
    _ -> False)
  Bytes.writeFile selectedPath original
  _ <- publish (Just (key second)) [RemovedEvidence itemA] >>= right
  assert "removal did not reclaim payload" . null =<< listDirectory payloadDirectory

selectionProof :: IO ()
selectionProof = do
  scope <- right (directoryScope "/fixture")
  prefix <- right (relativePath "nested")
  revision <- right (gitRevision (replicate 40 'a'))
  plugin <- right (pluginName "folder")
  manifest <- right (relativePath "kyyn-plugin.dhall")
  source <- right (relativePath "src/Folder.hs")
  tree <- right (fileTree [(manifest,"{ name = \"folder\", entryModule = \"Folder\" }"),
    (source,"module Folder where\n")])
  let kb = KnowledgeBase (Repository scope) (Subtree prefix)
      configuration :: Bytes.ByteString
      configuration = "[{ name = \"sales\", binding = \"sales\", connector = < Folder : { path : Text } >.Folder { path = \"/source\" } }]"
      git = interpret $ \_ request -> case request of
        ReadTreeAt (Repository actual) selectedRevision (Subtree path) []
          | actual == scope && selectedRevision == revision && relativeName path == "nested/root/plugins/packages/folder/source" -> pure (Right tree)
        ReadFileAt (Repository actual) selectedRevision path
          | actual == scope && selectedRevision == revision && relativeName path == "nested/root/plugins/config/folder.dhall" -> pure (Right (Just configuration))
        _ -> error "Evidence selection read outside its selected package/configuration"
      noStore = interpret $ \_ (_ :: EvidenceStore m a) -> error "Source selection opened the evidence store"
      selectionResult = runPureEff . runDhallHandling . git . noStore . runEvidenceInspection $
        Inspection.selectEvidence kb revision plugin (ConnectorName "sales")
  EvidenceSelection ref kind (PackageIdentity identity) <- right selectionResult
  captured <- right (guestSources source [(manifest,"{ name = \"folder\", entryModule = \"Folder\" }"),(source,"module Folder where\n")])
  assert "compiler-free selection differs from preparation package identity" (PackageIdentity identity == packageIdentity captured)
  assert "lightweight selection changed connector identity"
    (ref == ConnectorInstanceRef plugin "sales" && kind == ConnectorTypeName "Folder" && length identity == 64)

cleanupFailureProof :: IO ()
cleanupFailureProof = do
  scope <- right (directoryScope "/recording-kb")
  let files = interpret $ \_ operation -> case operation of
        EntryExists _ _ -> pure False
        ReadOptionalBytes _ _ -> pure (Just "*")
        ListDirectory _ -> raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic Failure.ListDirectory "payloads" "fixture failure"))
        _ -> error "Unexpected filesystem operation during empty publication"
      (outcome,(stored,trace)) = runPureEff . State.runState ((Nothing,[]) :: Recording) . runFailure . files
        . runDhallHandling . recordDocuments . noBlobs . runEvidenceStore scope $
          publishFetch selection contract Nothing Nothing [] Nothing
  assert "cleanup failure was not identified as post-publication" (case outcome of
    Left failure -> "was published" `Text.isInfixOf` Text.pack (show failure)
    Right _ -> False)
  assert "cleanup failure lost the publication point" (trace == ["read","stamp","replace"])
  bytes <- maybe (fail "Cleanup failure erased committed index") pure stored
  _ <- right (runPureEff (runDhallHandling (Index.decodeIndex bytes)))
  pure ()
