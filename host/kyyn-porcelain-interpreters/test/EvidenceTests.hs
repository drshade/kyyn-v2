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
import Kyyn.Domain.DataType (DataType(..), Shape(..))
import Kyyn.Domain.Evidence
import Kyyn.Domain.Path (DirectoryScope, directoryScope)
import Kyyn.Domain.Plugin (pluginName, PackageIdentity(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Evidence (EvidenceRef(EvidenceRef))
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
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Protocol.EvidencePersistence
import System.Directory (createDirectory, removeDirectory, doesFileExist, doesDirectoryExist, listDirectory)
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
value name = Evidence (EvidenceFingerprint name) ["/source/" ++ name] (CheckedValue (contractId contract) (String (Text.pack ("payload-only-" ++ name))))

execute :: DirectoryScope -> Eff '[EvidenceStore, DocumentPersistence, DhallHandling, FileSystem, Failure, IOE] a -> IO a
execute scope action = runEff (runFailure (runFileSystemIO scope (runDhallHandling (runDocumentPersistenceIO $ runEvidenceStore scope action)))) >>= right

key :: EvidenceSnapshotRef -> FetchId
key (EvidenceSnapshotRef _ _ identity) = identity

main :: IO ()
main = do
  recordingProof
  let first = [NewEvidence itemA (value "old"),NewEvidence itemB (value "removed")]
      second = [UpdatedEvidence itemA (value "new"),RemovedEvidence itemB]
  initial <- right (applyChanges [] first)
  assert "duplicate new ID accepted" (isLeft (applyChanges initial [NewEvidence itemA (value "bad")]))
  assert "missing update accepted" (isLeft (applyChanges [] second))
  assert "missing removal accepted" (isLeft (applyChanges [] [RemovedEvidence itemB]))
  assert "empty ID accepted" (isLeft (applyChanges [] [NewEvidence (EvidenceId "") (value "bad")]))
  assert "empty fingerprint accepted" (isLeft (applyChanges [] [NewEvidence itemA (value "")]))
  assert "same-fingerprint update accepted" (case applyChanges initial [UpdatedEvidence itemA (value "old")] of
    Left (InvalidDelta _) -> True; _ -> False)
  let sameTokenDifferentPayload = Evidence (EvidenceFingerprint "old") []
        (CheckedValue (contractId contract) (String "different"))
  assert "same-fingerprint update accepted because payload differed"
    (case applyChanges initial [UpdatedEvidence itemA sameTokenDifferentPayload] of
      Left (InvalidDelta _) -> True; _ -> False)
  sequential <- right (applyChanges [] [NewEvidence itemA (value "a"),UpdatedEvidence itemA (value "b"),RemovedEvidence itemA])
  assert "changes not applied in order" (null sequential)
  (_,markers) <- right (recordChanges instanceA [] first)
  let state = EvidenceState (Just (FetchId "one")) initial [Fetch (FetchId "one") Nothing "2026-09-11" markers]
  assert "incomplete scope history accepted" (isLeft (resolveCapture instanceA producer (FetchId "one")
    [Fetch (FetchId "one") (Just (FetchId "lost")) "2026-09-11" markers] (FetchId "one")))
  assert "values without a fetch accepted" (isLeft (validateState (EvidenceState Nothing initial [])))
  assert "corrupt current metadata accepted" (isLeft (validateState
    (EvidenceState (Just (FetchId "one")) [] [Fetch (FetchId "one") Nothing "2026-09-11" markers])))
  bytes <- right (runPureEff (runDhallHandling (encodeState producer contract state)))
  restored <- right (runPureEff (runDhallHandling (decodeState producer contract bytes)))
  assert "Dhall state round trip differs" (state == restored)
  assert "state is not Dhall" (Bytes.isInfixOf "New" bytes && Bytes.isInfixOf "payload" bytes)
  header <- right (runPureEff (runDhallHandling (decodeHeader bytes)))
  assert "header loses current" (header == EvidenceHeader (PackageIdentity "package-contents-one")
    (contractFingerprint (contractId contract)) (FetchId "one"))
  assert "Dhall import accepted" (isLeft (runPureEff (runDhallHandling (decodeHeader "./untrusted.dhall"))))
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
    let run :: Eff '[EvidenceStore, DocumentPersistence, DhallHandling, FileSystem, Failure, IOE] a -> IO a
        run = execute scope
        load instanceRef owner = run (loadCurrentEvidence instanceRef owner contract) >>= right
        listing instanceRef owner = run (runEvidenceInspection (Inspection.currentEvidence instanceRef owner contract))
        storePath = directory </> ".kyyn/evidence/folder-73616c6573"
        statePath = storePath </> "state.dhall"
    empty <- load instanceA producer
    assert "new store has current evidence" (empty == Nothing)
    missing <- run (readFetchHistory instanceA producer contract)
    assert "missing fetch looks like an empty successful fetch" (missing == Left NotFetched)
    absentListing <- listing instanceA producer
    assert "listing unfetched evidence succeeded" (absentListing == Left [evidenceProblemDiagnostic NotFetched])
    let ignorePath = directory </> ".kyyn/.gitignore"
    ignoredBefore <- doesFileExist ignorePath
    assert "read wrote the ignore file" (not ignoredBefore)
    f1 <- run (publishFetch instanceA producer contract Nothing first) >>= right
    listedFirst <- listing instanceA producer >>= right
    assert "listing lost first IDs or fingerprints" (listedFirst == EvidenceCapture f1
      [(itemA,EvidenceFingerprint "old"),(itemB,EvidenceFingerprint "removed")])
    let emptyInstance = ConnectorInstanceRef (either error id (pluginName "folder")) "empty"
    emptyFetch <- run (publishFetch emptyInstance producer contract Nothing []) >>= right
    listedEmpty <- listing emptyInstance producer >>= right
    assert "fetched empty capture refused" (listedEmpty == EvidenceCapture emptyFetch [])
    saved <- load instanceA producer
    ignore <- Bytes.readFile ignorePath
    assert "first publication did not ignore local evidence" (ignore == "*\n")
    Bytes.writeFile ignorePath "*\n# preserve local comment\n"
    independent <- run (publishFetch instanceB producer contract Nothing [NewEvidence itemA (value "independent")]) >>= right
    f2 <- run (publishFetch instanceA producer contract (Just (key f1)) second) >>= right
    preservedIgnore <- Bytes.readFile ignorePath
    assert "publication rewrote existing ignore file" (preservedIgnore == "*\n# preserve local comment\n")
    latest <- load instanceA producer
    listedLatest <- listing instanceA producer >>= right
    assert "listing retained removed item or old fingerprint" (listedLatest == EvidenceCapture f2 [(itemA,EvidenceFingerprint "new")])
    listedOther <- listing instanceB producer >>= right
    assert "listing mixed instances" (listedOther == EvidenceCapture independent [(itemA,EvidenceFingerprint "independent")])
    oldCapture <- run (resolveEvidenceCapture instanceA (key f1)) >>= right
    latestCapture <- run (resolveEvidenceCapture instanceA (key f2)) >>= right
    assert "old fetch replaced by latest" (oldCapture == EvidenceCapture f1
      [(itemA,EvidenceFingerprint "old"),(itemB,EvidenceFingerprint "removed")])
    assert "metadata removal not reconstructed" (latestCapture == EvidenceCapture f2 [(itemA,EvidenceFingerprint "new")])
    assert "unknown scope substituted latest" . (== Left CursorUnavailable) =<<
      run (resolveEvidenceCapture instanceA (FetchId "missing"))
    assert "foreign scope accepted" . (== Left CursorUnavailable) =<<
      run (resolveEvidenceCapture instanceA (key independent))
    (metadataHeader,metadataHistory) <- Bytes.readFile statePath >>= right . runPureEff . runDhallHandling . decodeHistory
    assert "history projection lost header" (metadataHeader == EvidenceHeader (PackageIdentity "package-contents-one")
      (contractFingerprint (contractId contract)) (key f2))
    assert "history projection lost retained fetches" (length metadataHistory == 2)
    other <- load instanceB producer
    assert "current payload or removal incorrect" (latest == Just (CurrentEvidence f2 [(itemA,value "new")]))
    assert "loaded invocation input changed after publication" (saved == Just (CurrentEvidence f1 initial))
    assert "instances share evidence" (other == Just (CurrentEvidence independent [(itemA,value "independent")]))
    persisted <- Bytes.readFile statePath
    assert "replaced or removed payload remains on disk"
      (not (Bytes.isInfixOf "payload-only-old" persisted || Bytes.isInfixOf "payload-only-removed" persisted)
        && Bytes.isInfixOf "payload-only-new" persisted)
    withSystemTempDirectory "kyyn-other-evidence-" $ \otherDirectory -> do
      otherScope <- right (directoryScope otherDirectory)
      otherHead <- execute otherScope (evidenceHead instanceA) >>= right
      assert "same instance leaked into another KB" (otherHead == Nothing)
    (_,summaries) <- run (listEvidenceChanges instanceA producer contract (Just (key f1))) >>= right
    assert "summary metadata/citation wrong" (summaries ==
      [EvidenceChangeSummary (key f2) (Just (key f1)) Updated itemA (EvidenceFingerprint "new") (EvidenceRef "folder" "sales" "a.txt" ["/source/new"]),
       EvidenceChangeSummary (key f2) (Just (key f1)) Removed itemB (EvidenceFingerprint "removed") (EvidenceRef "folder" "sales" "b.txt" ["/source/removed"])])
    (at,batches) <- run (readFetchHistory instanceA producer contract) >>= right
    assert "history is not metadata through the current fetch" (at == f2 && length batches == 2)
    assert "fetch timestamp is not ISO 8601 UTC" (all (\(FetchSummary _ _ time _) ->
      case iso8601ParseM time :: Maybe UTCTime of Just _ -> last time == 'Z'; Nothing -> False) batches)
    foreignBase <- run (listEvidenceChanges instanceA producer contract (Just (key independent)))
    assert "foreign cursor treated as empty" (foreignBase == Left CursorUnavailable)
    currentSpan <- run (listEvidenceChanges instanceA producer contract (Just (key f2))) >>= right
    assert "current cursor did not produce an empty span" (currentSpan == (f2,[]))
    stale <- run (publishFetch instanceA producer contract (Just (key f1)) [])
    assert "stale base accepted" (stale == Left BaseSnapshotConflict)
    wrong <- run (publishFetch instanceA producer contract (Just (key f2)) [NewEvidence itemA (value "bad")])
    assert "invalid batch accepted" (isLeft wrong)
    invalidPayload <- run (publishFetch instanceA producer contract (Just (key f2))
      [UpdatedEvidence itemA (Evidence (EvidenceFingerprint "invalid-payload") [] (CheckedValue (contractId contract) (Bool True)))])
    assert "forged checked-value shape accepted" (isLeft invalidPayload)
    let boolContract = either (error . show) id (checkContract BoolType (SchemaMetadata [] [] []))
    wrongContract <- run (loadCurrentEvidence instanceA producer boolContract)
    assert "evidence decoded under wrong contract" (wrongContract == Left ProducerContractChanged)
    tip <- run (evidenceHead instanceA) >>= right
    assert "refusal changed head" (tip == Just (key f2))
    (left,rightResult) <- concurrently
      (run (publishFetch instanceA producer contract (Just (key f2)) []))
      (run (publishFetch instanceA producer contract (Just (key f2)) []))
    f3 <- case (left,rightResult) of
      (Right result,Left BaseSnapshotConflict) -> pure result
      (Left BaseSnapshotConflict,Right result) -> pure result
      _ -> fail "concurrent writers did not produce exactly one publication"
    let changedProducer = EvidenceProducer (PackageIdentity "package-contents-two") (contractId contract)
    incompatible <- run (loadCurrentEvidence instanceA changedProducer contract)
    assert "same-schema producer change accepted" (incompatible == Left ProducerContractChanged)
    incompatibleListing <- listing instanceA changedProducer
    assert "listing swallowed producer refusal" (incompatibleListing == Left [evidenceProblemDiagnostic ProducerContractChanged])
    failedReset <- run (publishFetch instanceA changedProducer contract (Just (key f3)) [RemovedEvidence itemA])
    assert "invalid new-producer batch accepted" (isLeft failedReset)
    retained <- load instanceA producer
    assert "failed producer refetch changed evidence" (retained == Just (CurrentEvidence f3 [(itemA,value "new")]))
    changed <- run (publishFetch instanceA changedProducer contract (Just (key f3)) [NewEvidence itemA (value "refetched")]) >>= right
    oldProducer <- run (loadCurrentEvidence instanceA producer contract)
    assert "old producer reinterpreted" (oldProducer == Left ProducerContractChanged)
    (_,reset) <- run (readFetchHistory instanceA changedProducer contract) >>= right
    assert "new producer carried previous change base" (case reset of [FetchSummary _ Nothing _ _] -> True; _ -> False)
    lostCursor <- run (listEvidenceChanges instanceA changedProducer contract (Just (key f3)))
    assert "reset producer retained old cursor" (lostCursor == Left CursorUnavailable)
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
    fresh <- run (publishFetch instanceA changedProducer contract Nothing []) >>= right
    emptyCapture <- load instanceA changedProducer
    assert "empty capture confused with not fetched" (emptyCapture == Just (CurrentEvidence fresh []))
    unavailable <- run (listEvidenceChanges instanceA changedProducer contract (Just (key changed)))
    assert "cleared cursor remained usable" (unavailable == Left CursorUnavailable)
    Bytes.writeFile statePath "{ malformed = True }"
    bad <- run (loadCurrentEvidence instanceA changedProducer contract)
    assert "malformed evidence became absent" (case bad of Left (InvalidEvidence _) -> True; _ -> False)
    badFetch <- run (publishFetch instanceA changedProducer contract (Just (key fresh)) [])
    assert "fetch silently replaced unreadable data" (isLeft badFetch)
    _ <- run (clearEvidence instanceA)
    _ <- load instanceA changedProducer
    createDirectory storePath
    createDirectory statePath
    failedRead <- runEff (runFailure (runFileSystemIO scope (runDhallHandling (runDocumentPersistenceIO $ runEvidenceStore scope (evidenceHead instanceA)))))
    assert "storage error became absent evidence" (isLeft failedRead)
    removeDirectory statePath
    reopened <- run (evidenceHead instanceA) >>= right
    assert "operational failure left store locked" (reopened == Nothing)
  putStrLn "Evidence store: latest payloads, markers, Dhall, cursors, producer reset, clear and concurrent publication passed."

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
        . runDhallHandling . recordDocuments . runEvidenceStore scope $ do
          first <- publishFetch instanceA producer contract Nothing [NewEvidence itemA (value "recorded")]
          conflict <- publishFetch instanceA producer contract Nothing []
          second <- publishFetch instanceA producer contract (Just (FetchId "00000001")) []
          pure (first,conflict,second)
  (first,conflict,second) <- right result
  _ <- right first
  assert "recorded semantic store lost CAS refusal" (conflict == Left BaseSnapshotConflict)
  assert "collision was not redrawn" (second == Right (EvidenceSnapshotRef instanceA producer (FetchId "00000002")))
  assert "conflict wrote or collision reused an ID"
    (trace == ["read","stamp","replace","read","read","stamp","stamp","replace"])
