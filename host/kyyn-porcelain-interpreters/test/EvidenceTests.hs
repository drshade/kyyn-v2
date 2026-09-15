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
import Kyyn.Plumbing.Capability.FileSystem (FileSystem(..))
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence(..), DocumentAccess(..), DocumentStamp(..))
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Protocol.EvidencePersistence
import System.Directory (createDirectory, removeDirectory, doesFileExist, doesDirectoryExist)
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
value name = Evidence ["/source/" ++ name] (CheckedValue (contractId contract) (String (Text.pack name)))

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
  sequential <- right (applyChanges [] [NewEvidence itemA (value "a"),UpdatedEvidence itemA (value "b"),RemovedEvidence itemA])
  assert "changes not applied in order" (null sequential)
  let state = EvidenceState Nothing [] (Just (FetchId "one")) initial [Fetch (FetchId "one") Nothing "2026-09-11" first]
  assert "unrecorded initial payloads accepted" (isLeft (validateState (EvidenceState Nothing initial Nothing initial [])))
  assert "corrupt derivative accepted" (isLeft (validateState (EvidenceState Nothing [] (Just (FetchId "one")) []
    [Fetch (FetchId "one") Nothing "2026-09-11" first])))
  bytes <- right (runPureEff (runDhallHandling (encodeState producer contract state)))
  restored <- right (runPureEff (runDhallHandling (decodeState producer contract bytes)))
  assert "Dhall state round trip differs" (state == restored)
  assert "state is not Dhall" (Bytes.isInfixOf "New" bytes && Bytes.isInfixOf "payload" bytes)
  badBytes <- right (runPureEff (runDhallHandling (decodeHeader bytes)))
  assert "header loses current" (badBytes == EvidenceHeader (PackageIdentity "package-contents-one") (contractFingerprint (contractId contract)) (Just (FetchId "one")) Nothing [FetchId "one"])
  assert "Dhall import accepted" (isLeft (runPureEff (runDhallHandling (decodeHeader "./untrusted.dhall"))))
  let wrongProducer = EvidenceProducer (PackageIdentity "different-source") (contractId contract)
      headerOnly = interpret $ \_ request -> case request of
        DecodeValue (Record fields) _ | map fst fields == ["producer","contract","current","baseline","fetches"] ->
          pure (Right (object ["producer" .= ("package-contents-one" :: String),
            "contract" .= contractFingerprint (contractId contract),
            "current" .= object ["tag" .= ("None" :: String)],
            "baseline" .= object ["tag" .= ("None" :: String)],"fetches" .= ([] :: [String])]))
        _ -> error "Producer refusal attempted payload decoding or encoding"
  assert "producer mismatch reached payload decoder"
    (runPureEff (headerOnly (decodeState wrongProducer contract bytes)) == Left ProducerContractChanged)
  withSystemTempDirectory "kyyn-evidence-" $ \directory -> do
    scope <- right (directoryScope directory)
    let run :: Eff '[EvidenceStore, DocumentPersistence, DhallHandling, FileSystem, Failure, IOE] a -> IO a
        run = execute scope
    empty <- run (evidenceHead instanceA) >>= right
    assert "new store has a head" (empty == Nothing)
    missing <- run (selectEvidence instanceA producer CurrentEvidence)
    assert "missing snapshot looks empty" (missing == Left HistoryUnavailable)
    let ignorePath = directory </> ".kyyn/.gitignore"
    ignoredBefore <- doesFileExist ignorePath
    assert "read wrote the ignore file" (not ignoredBefore)
    f1 <- run (publishFetch instanceA producer contract Nothing first) >>= right
    ignore <- Bytes.readFile ignorePath
    assert "first publication did not ignore local evidence" (ignore == "*\n")
    Bytes.writeFile ignorePath "*\n# preserve local comment\n"
    independent <- run (publishFetch instanceB producer contract Nothing [NewEvidence itemA (value "independent")]) >>= right
    f2 <- run (publishFetch instanceA producer contract (Just (key f1)) second) >>= right
    preservedIgnore <- Bytes.readFile ignorePath
    assert "publication rewrote existing ignore file" (preservedIgnore == "*\n# preserve local comment\n")
    old <- run (readEvidence f1 contract itemA) >>= right
    latest <- run (readEvidence f2 contract itemA) >>= right
    other <- run (readEvidence independent contract itemA) >>= right
    removed <- run (readEvidence f2 contract itemB) >>= right
    assert "historical payload followed latest" (old == Just (value "old"))
    assert "current payload incorrect" (latest == Just (value "new"))
    assert "instances share evidence" (other == Just (value "independent"))
    withSystemTempDirectory "kyyn-other-evidence-" $ \otherDirectory -> do
      otherScope <- right (directoryScope otherDirectory)
      otherHead <- execute otherScope (evidenceHead instanceA) >>= right
      assert "same instance leaked into another KB" (otherHead == Nothing)
    assert "removed item still exists" (removed == Nothing)
    summaries <- run (listEvidenceChanges f2 contract (Just (key f1))) >>= right
    assert "summary metadata/citation wrong" (summaries ==
      [EvidenceChangeSummary (key f2) (Just (key f1)) Updated itemA (EvidenceRef "folder" "sales" "a.txt" ["/source/new"]),
       EvidenceChangeSummary (key f2) (Just (key f1)) Removed itemB (EvidenceRef "folder" "sales" "b.txt" ["/source/removed"])])
    batch <- run (readFetchesBetween f2 contract (Just (key f1))) >>= right
    assert "fetch delta lost payload" (case batch of [Fetch _ _ _ changes] -> changes == second; _ -> False)
    assert "fetch timestamp is not ISO 8601 UTC" (case batch of
      [Fetch _ _ at _] -> case iso8601ParseM at :: Maybe UTCTime of Just _ -> last at == 'Z'; Nothing -> False
      _ -> False)
    foreignBase <- run (readFetchesBetween f2 contract (Just (key independent)))
    assert "foreign cursor treated as empty" (foreignBase == Left HistoryUnavailable)
    stale <- run (publishFetch instanceA producer contract (Just (key f1)) [])
    assert "stale base accepted" (stale == Left BaseSnapshotConflict)
    wrong <- run (publishFetch instanceA producer contract (Just (key f2)) [NewEvidence itemA (value "bad")])
    assert "invalid batch accepted" (isLeft wrong)
    invalidPayload <- run (publishFetch instanceA producer contract (Just (key f2))
      [UpdatedEvidence itemA (Evidence [] (CheckedValue (contractId contract) (Bool True)))])
    assert "forged checked-value shape accepted" (isLeft invalidPayload)
    let boolContract = either (error . show) id (checkContract BoolType (SchemaMetadata [] [] []))
    wrongContract <- run (readEvidence f2 boolContract itemA)
    assert "snapshot decoded under wrong contract" (wrongContract == Left ProducerContractChanged)
    tip <- run (evidenceHead instanceA) >>= right
    assert "refusal changed head" (tip == Just (key f2))
    (left,rightResult) <- concurrently
      (run (publishFetch instanceA producer contract (Just (key f2)) []))
      (run (publishFetch instanceA producer contract (Just (key f2)) []))
    assert "concurrent writers both published" (case (left,rightResult) of
      (Right _,Left BaseSnapshotConflict) -> True
      (Left BaseSnapshotConflict,Right _) -> True
      _ -> False)
    f3 <- run (selectEvidence instanceA producer CurrentEvidence) >>= right
    _ <- run (deleteEvidenceHistory instanceA producer contract) >>= right
    oldGone <- run (selectEvidence instanceA producer (AtFetch (key f1)))
    selfSpan <- run (readFetchesBetween f3 contract (Just (key f3)))
    historyGone <- run (readFetchesBetween f3 contract (Just (key f1)))
    retained <- run (readEvidence f3 contract itemA) >>= right
    assert "deleted history silently usable" (oldGone == Left HistoryUnavailable && historyGone == Left HistoryUnavailable)
    assert "baseline self-span needs deleted deltas" (selfSpan == Right [])
    assert "history deletion removed current" (retained == Just (value "new"))
    f4 <- run (publishFetch instanceA producer contract (Just (key f3)) [UpdatedEvidence itemA (value "four")]) >>= right
    f5 <- run (publishFetch instanceA producer contract (Just (key f4)) [UpdatedEvidence itemA (value "five")]) >>= right
    postDeletion <- run (readEvidence f4 contract itemA) >>= right
    assert "historical reconstruction after deletion failed" (postDeletion == Just (value "four"))
    afterDeletion <- run (readFetchesBetween f5 contract (Just (key f4))) >>= right
    assert "new history after deletion unavailable" (length afterDeletion == 1)
    baseline <- run (selectEvidence instanceA producer (AtFetch (key f3))) >>= right
    baselineValue <- run (readEvidence baseline contract itemA) >>= right
    assert "baseline value lost after later fetches" (baselineValue == Just (value "new"))
    fromBaseline <- run (listEvidenceChanges f5 contract (Just (key f3))) >>= right
    assert "baseline span lost retained deltas" (fromBaseline ==
      [EvidenceChangeSummary (key f4) (Just (key f3)) Updated itemA (EvidenceRef "folder" "sales" "a.txt" ["/source/four"]),
       EvidenceChangeSummary (key f5) (Just (key f4)) Updated itemA (EvidenceRef "folder" "sales" "a.txt" ["/source/five"])])
    unknown <- run (readFetchesBetween (EvidenceSnapshotRef instanceA producer (FetchId "unknown")) contract (Just (FetchId "unknown")))
    assert "unknown self-span silently accepted" (unknown == Left HistoryUnavailable)
    let changedProducer = EvidenceProducer (PackageIdentity "package-contents-two") (contractId contract)
    incompatible <- run (selectEvidence instanceA changedProducer CurrentEvidence)
    assert "same-schema producer change accepted" (incompatible == Left ProducerContractChanged)
    changed <- run (publishFetch instanceA changedProducer contract (Just (key f5)) [NewEvidence itemA (value "refetched")]) >>= right
    oldProducer <- run (readEvidence f5 contract itemA)
    assert "old producer reinterpreted" (oldProducer == Left ProducerContractChanged)
    reset <- run (readFetchesBetween changed contract Nothing) >>= right
    assert "new producer carried previous delta base" (case reset of [Fetch _ Nothing _ _] -> True; _ -> False)
    archives <- doesDirectoryExist (directory </> ".kyyn/evidence/folder-73616c6573/archives")
    assert "producer update archived replaced contents" (not archives)
    run (clearEvidence instanceA)
    remaining <- doesDirectoryExist (directory </> ".kyyn/evidence/folder-73616c6573")
    assert "clear retained the instance cache" (not remaining)
    absent <- run (evidenceHead instanceA) >>= right
    otherStill <- run (readEvidence independent contract itemA) >>= right
    assert "clear failed or crossed instance boundary" (absent == Nothing && otherStill == Just (value "independent"))
    let statePath = directory </> ".kyyn/evidence/folder-73616c6573/state.dhall"
    createDirectory statePath
    failedRead <- runEff (runFailure (runFileSystemIO scope (runDhallHandling (runDocumentPersistenceIO $ runEvidenceStore scope (evidenceHead instanceA)))))
    assert "storage error became absent history" (isLeft failedRead)
    removeDirectory statePath
    reopened <- run (evidenceHead instanceA) >>= right
    assert "operational failure left store locked" (reopened == Nothing)
  putStrLn "Evidence store: delta, Dhall, history, deletion, producer and concurrent publication checks passed."

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
    FreshStamp -> State.put (document,trace ++ ["stamp"]) >> pure (DocumentStamp "recorded" "2026-09-14T00:00:00Z")
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
          pure (first,conflict)
  (first,conflict) <- right result
  _ <- right first
  assert "recorded semantic store lost CAS refusal" (conflict == Left BaseSnapshotConflict)
  assert "conflict wrote or allocated a revision" (trace == ["read","stamp","replace","read"])
