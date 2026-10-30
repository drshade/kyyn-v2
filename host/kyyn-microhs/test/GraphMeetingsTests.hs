-- Generated Meetings adapters under GHC and MicroHs with recorded providers.
-- Covers initial/overlap/backfill windows and independent 403 skips, repeated calendar URLs, artifact identity,
-- artifact-window boundaries, narrow resolution-404 skips, pagination, capture-once,
-- retention, failed downloads/pages, credential scope,
-- enabled-member selection, tenant user pagination, policy/calendar denials and unavailable mailboxes,
-- captured VTT text, UTF-8/blob refusals and fingerprint parity. No live tenant calls.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (Value(..), FromJSON, object, (.=), (.:), encode, toJSON)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Map
import Data.Aeson.Types (parseEither, withObject, parseJSON)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.IORef
import Data.List (isSuffixOf, nub)
import Data.Version (showVersion)
import Effectful (runEff, runPureEff)
import Kyyn.Domain.DataType (DataType(..))
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Path
import Kyyn.MicroHs.Inspection (inspectDataType)
import Kyyn.Plumbing.Capability.FileSystem (readTree)
import qualified Kyyn.Plumbing.Capability.ContentDigest as Digest
import Kyyn.Plumbing.Interpreter.ContentDigest (runContentDigest)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Protocol.PluginInvocation
import Kyyn.Plumbing.Protocol.Blob (downloadResult)
import Kyyn.Types.Blob (BlobRef(..), BlobResponse(..))
import System.Directory (findExecutable)
import System.Environment (getEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.Info (compilerVersion)
import System.IO.Temp (withSystemTempDirectory)
import PluginFetchTests (compileBoth, brokerWith, Scenario(..))

main :: IO ()
main = withSystemTempDirectory "kyyn-graph-meetings-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  toolchain <- getEnv "KYYN_TEST_TOOLCHAIN"
  compiler <- findExecutable ("ghc-" ++ showVersion compilerVersion) >>= maybe (fail "Matching GHC required") pure
  scope <- right (directoryScope temporary)
  let directories = ["shared/kyyn-types/src","guest/kyyn-sdk/src","guest/kyyn-runtime/src","vendor/json","vendor/transformers","plugins/microsoft-graph/src"]
      load folder = do
        root <- right (directoryScope (repo </> folder))
        runEff (runFailure (runFileSystemIO scope (readTree root))) >>= right
      inspect name = fmap fst <$> inspectDataType toolchain (map (repo </>) directories) name >>= right
  sources <- filter (isSuffixOf ".hs" . relativeName . fst) . concatMap files <$> mapM load directories
  config <- inspect "MicrosoftGraph.Meetings.Types.MeetingsConfig"
  payload <- inspect "MicrosoftGraph.Meetings.Types.MeetingArtifact"
  options <- inspect "MicrosoftGraph.Meetings.Types.MeetingsFetch"
  position <- inspect "MicrosoftGraph.Meetings.Types.MeetingsPosition"
  reportType <- inspect "MicrosoftGraph.Meetings.Types.MeetingsReport"
  adapter <- right (statefulAcquisitionSources config payload (Just options) position reportType "MicrosoftGraph.Meetings.fetch" sources)
  (programs,_) <- compileBoth temporary toolchain compiler "meetings" adapter
  results <- newIORef []
  forM_ programs $ \program -> do
    (respond,trace) <- provider [] "normal"
    (result,_,status) <- brokerWith Normal respond program (input now Nothing False)
    assert "meetings adapter exit" (status == ExitSuccess)
    forM_ [1,8 :: Int] $ \width -> do
      (sameProvider,_) <- provider [] "normal"
      let selectedWidth = change ["concurrency"] (const (text (Text.pack (show width)))) (input now Nothing False)
      (sameResult,_,sameStatus) <- brokerWith Normal sameProvider program selectedWidth
      assert "width changed recorded Meetings artifacts, position or report" (sameStatus == ExitSuccess && sameResult == result)

    output <- maybe (fail "Missing result") (get "value") result
    publicReport <- get "report" output
    assert "report lower bound differs from discovery" . (== ("2026-09-20T12:00:00Z" :: Text.Text)) =<< get "since" publicReport
    assert "report upper bound differs from discovery" . (== now) =<< get "until" publicReport
    reportScope <- get "scope" publicReport
    assert "application scope missing" . (== ("EnabledMemberMailboxes" :: Text.Text)) =<< get "tag" reportScope
    assert "ordinary listing reported a cap" . null =<< (get "coverageLimits" publicReport :: IO [Value])
    changes <- get "changes" output :: IO [Value]
    assert "all artifacts must be captured" (length changes == 3)
    stored <- mapM (\c -> do v <- get "value" c; (,) <$> get "id" v <*> get "evidence" v) changes :: IO [(Text.Text,Value)]
    assert "artifact kind prevents ID collision" (length (nub (map fst stored)) == 3)
    artifacts <- mapM (get "payload" . snd) stored
    let available = [v | Object fields <- artifacts, Just (String "Available") <- [Map.lookup "tag" fields], Just v <- [Map.lookup "value" fields]]
    assert "in-window artifacts are available" (length available == 3)
    let attendance = [v | Object fields <- available, Just (String "Attendance") <- [Map.lookup "tag" fields], Just v <- [Map.lookup "value" fields]]
    [report] <- pure attendance
    participants <- get "attendees" report :: IO [Value]
    assert "attendance pagination lost participants" (length participants == 2)
    firstParticipant:_ <- pure participants
    identity <- get "identity" firstParticipant >>= get "value"
    assert "participant identity lost" . (== tagged "Some" (text "guest-id")) =<< get "id" identity
    assert "ACS identity resource lost" . (== tagged "Some" (text "acs-resource")) =<< get "azureCommunicationServicesResourceId" identity
    intervals <- get "attendanceIntervals" firstParticipant :: IO [Value]
    assert "participant intervals lost" (length intervals == 2)
    events <- readIORef trace
    assert "disabled/guest calendars queried" (not (any (\url -> any (`Text.isInfixOf` url) ["/users/disabled/","/users/guest/"]) events))
    assert "calendar page size missing" (any (Text.isInfixOf "&$top=1000") events)
    assert "default window is thirty days" (any (Text.isInfixOf "startDateTime=2026-09-20T12%3A00%3A00Z") events)
    assert "repeated calendar join URL refetched artifacts" (length (filter (Text.isInfixOf "onlineMeetings?$filter=") events) == 1)
    assert "throttled blob did not retry" (length (filter (== "blob") events) == 3 && "wait" `elem` events)
    assert "join URL apostrophe was not escaped for OData" (any (Text.isInfixOf "meet%27%27a") events)
    modifyIORef' results (output:)
    forM_ [("cap-49",0),("cap-50",1)] $ \(scenario,expectedLimits) -> do
      (limited,_) <- provider [] scenario
      (limitedResult,_,_) <- brokerWith Normal limited program (input now Nothing False)
      limitedOutput <- maybe (fail "Missing limited result") (get "value") limitedResult
      limits <- get "report" limitedOutput >>= get "coverageLimits" :: IO [Value]
      assert "attendance cap boundary wrong" (length limits == expectedLimits)
      assert "cap warning suppressed returned artifacts" . (==3) . length =<< changesFrom limitedResult
    let old = stored
    (again,againTrace) <- provider old "normal"
    (repeatResult,_,_) <- brokerWith Normal again program (inputWithPrior "2026-10-27T12:00:00Z" Nothing False (Just now))
    assert "capture-once changed artifacts" . null =<< changesFrom repeatResult
    repeatEvents <- readIORef againTrace
    assert "repeat captured payloads again" (not ("blob" `elem` repeatEvents) && not (any (Text.isInfixOf "/attendanceRecords") repeatEvents))
    assert "overlap must cover gap since last success" (any (Text.isInfixOf "startDateTime=2026-10-19T12%3A00%3A00Z") repeatEvents)
    (outside,outsideTrace) <- provider old "late"
    (outsideResult,_,_) <- brokerWith Normal outside program (inputWithPrior "2026-10-22T12:00:00Z" Nothing False (Just "2026-10-21T12:00:00Z"))
    assert "older meetings were rechecked outside overlap" . null =<< changesFrom outsideResult
    assert "outside-window meeting was resolved" . not . any (Text.isInfixOf "onlineMeetings?$filter=") =<< readIORef outsideTrace
    outsidePosition <- maybe (fail "Missing empty fetch result") (get "value") outsideResult >>= get "position"
    assert "empty successful fetch did not advance boundary" . (== ("2026-10-22T12:00:00Z" :: Text.Text)) =<< get "lastSuccessfulFetch" outsidePosition
    (late,_) <- provider old "late"
    (lateResult,_,_) <- brokerWith Normal late program (inputWithPrior now Nothing False (Just now))
    assert "new artifact on an already captured meeting was skipped" . (==1) . length =<< changesFrom lateResult
    (aged,_) <- provider old "normal"
    (agedResult,_,_) <- brokerWith Normal aged program (input "2026-12-20T12:00:00Z" (Just "2026-09-01T00:00:00Z") False)
    ageChanges <- changesFrom agedResult
    assert "retention must truncate only remaining payloads" (length ageChanges == 3)
    forM_ ageChanges $ \c -> assert "retention removed identity" . (== ("SetPayload" :: Text.Text)) =<< get "tag" c
    forM_ [("transcripts-denied",1),("reports-denied",2),("records-denied",2),("content-denied",1),("resolution-denied",0)] $ \(scenario,count) -> do
      (deniedProvider,_) <- provider [] scenario
      (partial,_,_) <- brokerWith Normal deniedProvider program (input now Nothing False)
      partialOutput <- maybe (fail "Missing partial result") (get "value") partial
      assert ("403 skipped unrelated artifacts: " ++ Text.unpack scenario) . (== count) . length =<< changesFrom partial
      saved <- get "position" partialOutput
      assert "successful fetch boundary not saved" . (== now) =<< get "lastSuccessfulFetch" saved
      public <- get "report" partialOutput
      denied <- get "deniedRequests" public :: IO [Value]
      contexts <- mapM (get "context") denied :: IO [Value]
      assert "denied user identity missing" (length (nub contexts) == 1)
      assert "report exposed request URLs" (not ("graph.microsoft.com" `Text.isInfixOf` Text.pack (show public)))
      captured <- changesFrom partial >>= mapM (\c -> do v <- get "value" c; (,) <$> get "id" v <*> get "evidence" v)
      (restored,_) <- provider captured "normal"
      (recovered,_,_) <- brokerWith Normal restored program (change ["arguments","priorPosition"] (const (tagged "Some" saved)) (input now (Just "2026-09-20T12:00:00Z") False))
      assert "denied artifacts permanently skipped" . (== (3-count)) . length =<< changesFrom recovered
    forM_ [("unsupported",3),("missing-join",3),("unresolved",3),("ambiguous",3),("missing-organizer",3),("unresolved-only",0),("resolve-not-found",3),("resolve-not-found-only",0),("resolve-late-not-found",0)] $ \(scenario,count) -> do
      (skipProvider,_) <- provider [] scenario
      (partial,_,_) <- brokerWith Normal skipProvider program (input now Nothing False)
      assert ("bad meeting blocked good meeting: " ++ Text.unpack scenario) . (== count) . length =<< changesFrom partial
      saved <- maybe (fail "Missing skip result") (get "value") partial >>= get "position"
      assert "skipped meetings prevented boundary advance" . (== now) =<< get "lastSuccessfulFetch" saved
      public <- maybe (fail "Missing report") (get "value") partial >>= get "report"
      skips <- get "skippedMeetings" public :: IO [Value]
      assert "meeting skip diagnostics missing" (not (null skips))
      forM_ skips $ \note -> do
        ref <- get "reference" note >>= get "value" :: IO Text.Text
        why <- get "reason" note :: IO Text.Text
        assert "skip must identify meeting and reason" (not (Text.null ref) && not (Text.null why))
      if count == 0 then do
        (restored,_) <- provider [] "normal"
        (recovered,_,_) <- brokerWith Normal restored program (change ["arguments","priorPosition"] (const (tagged "Some" saved)) (input now (Just "2026-09-20T12:00:00Z") False))
        assert "unresolved meetings permanently excluded" . (==3) . length =<< changesFrom recovered
      else pure ()
    forM_ ["blob-failure","page-failure","artifact-unauthorized","artifact-error","foreign-page","cycle","resolution-error","malformed-artifact","resolve-unknown-404","transcript-not-found","report-not-found","records-not-found"] $ \scenario -> do
      (bad,_) <- provider [] scenario
      (failed,_,_) <- brokerWith Normal bad program (input now Nothing False)
      assert ("failure returned publishable data: " ++ Text.unpack scenario) . (== ("Left" :: Text.Text)) =<< maybe (fail "Missing failure") (get "tag") failed
    forM_ [now,"invalid"] $ \boundary -> do
      (rejected,_,_) <- brokerWith Normal (\_ _ _ _ -> fail "Invalid boundary invoked a host capability") program (input now (Just boundary) False)
      assert "invalid boundary accepted" . (== ("Left" :: Text.Text)) =<< maybe (fail "Missing boundary failure") (get "tag") rejected
    (invalidPosition,_,_) <- brokerWith Normal (\_ _ _ _ -> fail "Invalid position invoked host") program (inputWithPrior now Nothing False (Just "invalid"))
    assert "invalid position accepted" . (== ("Left" :: Text.Text)) =<< maybe (fail "Missing position rejection") (get "tag") invalidPosition
    (backfill,backfillTrace) <- provider [] "normal"
    (backfillResult,_,_) <- brokerWith Normal backfill program (inputWithPrior now (Just "2026-01-01T00:00:00Z") False (Just now))
    backfilled <- changesFrom backfillResult
    assert "explicit backfill did not capture old report" (length backfilled == 4)
    backfillPayloads <- mapM (\c -> get "value" c >>= get "evidence" >>= get "payload" >>= get "tag") backfilled :: IO [Text.Text]
    assert "backfilled old report was not truncated" (length (filter (== "Truncated") backfillPayloads) == 1)
    assert "explicit backfill ignored" . any (Text.isInfixOf "startDateTime=2026-01-01") =<< readIORef backfillTrace
    (windowProvider,windowTrace) <- provider [] "artifact-window"
    (windowResult,_,_) <- brokerWith Normal windowProvider program (input now (Just "2026-10-19T00:00:00Z") False)
    assert "artifact window boundaries" . (==7) . length =<< changesFrom windowResult
    windowRequests <- readIORef windowTrace
    assert "out-of-window artifact content requested" (not (any (Text.isInfixOf "out-window") windowRequests))
    assert "historical attendance records requested" (not (any (Text.isInfixOf "/attendanceReports/old/") windowRequests))
    (overlapProvider,_) <- provider [] "artifact-window"
    (overlapResult,_,_) <- brokerWith Normal overlapProvider program (inputWithPrior now Nothing False (Just now))
    assert "overlap did not constrain recurring-series artifacts" . (==2) . length =<< changesFrom overlapResult
    (delegated,delegatedTrace) <- provider [] "normal"
    (deviceResult,_,_) <- brokerWith Normal delegated program (input now Nothing True)
    assert "delegated path failed" . (==3) . length =<< changesFrom deviceResult
    deviceEvents <- readIORef delegatedTrace
    assert "delegated enumerated tenant or checked configured user" (not (any (Text.isInfixOf "/users") deviceEvents) && not (any (Text.isInfixOf "/me?$select=id") deviceEvents))
    (deniedArtifact,_) <- provider [] "transcripts-denied"
    (partialDevice,_,_) <- brokerWith Normal deniedArtifact program (input now Nothing True)
    assert "delegated independent artifact skip" . (==1) . length =<< changesFrom partialDevice
    deviceState <- maybe (fail "Missing delegated state") (get "value") partialDevice >>= get "report"
    assert "delegated denial context lost" . not . null =<< (get "deniedRequests" deviceState :: IO [Value])
    (forbidden,_) <- provider [] "forbidden"
    (deniedDevice,_,_) <- brokerWith Normal forbidden program (input now Nothing True)
    assert "delegated calendar denial was swallowed" . (== ("Left" :: Text.Text)) =<< maybe (fail "Missing denial") (get "tag") deniedDevice
    forM_ ["multi","multi-fallback","multi-alias","multi-supported"] $ \scenario -> do
      (multi,multiTrace) <- provider [] scenario
      (multiResult,_,_) <- brokerWith Normal multi program (input now Nothing False)
      delta <- changesFrom multiResult
      assert "multi-user artifact count" (length delta == if scenario == "multi-fallback" then 3 else 6)
      state <- maybe (fail "Missing tenant result") (get "value") multiResult >>= get "report"
      denials <- get "deniedRequests" state :: IO [Value]
      deniedContexts <- mapM (get "context") denials :: IO [Value]
      assert "tenant denial identities" (length (nub deniedContexts) == if scenario == "multi-fallback" then 3 else 2)
      unavailable <- get "unavailableUsers" state :: IO [Value]
      assert "unavailable mailbox identity" (length unavailable == 1)
      assert "tenant report contains transport URLs" (not ("graph.microsoft.com" `Text.isInfixOf` Text.pack (show state)))
      requests <- readIORef multiTrace
      assert "directory pagination missing" (any (Text.isInfixOf "/users?page=2") requests)
      assert "directory selection fields missing" ("https://graph.microsoft.com/v1.0/users?$select=id,accountEnabled,userType&$top=999" `elem` requests)
      assert "attendee calendar resolved shared meeting" (not (any (\url -> "/users/second-user/onlineMeetings?$filter=" `Text.isInfixOf` url && "meet%27%27a" `Text.isInfixOf` url) requests))
      assert "directory duplicate walked user twice" (length (filter (\url -> "/users/second-user/calendarView?startDateTime=" `Text.isInfixOf` url) requests) == 1)
    forM_ ["users-denied","users-page-failure","users-foreign","users-cycle","users-bad-enabled","users-missing-type","unexpected-mailbox-error"] $ \scenario -> do
      (bad,badTrace) <- provider [] scenario
      (failed,_,_) <- brokerWith Normal bad program (input now Nothing False)
      assert ("directory/unexpected error was swallowed: " ++ Text.unpack scenario) . (== ("Left" :: Text.Text)) =<< maybe (fail "Missing failure") (get "tag") failed
      if scenario == "unexpected-mailbox-error" then pure () else
        assert "partial directory was used" . not . any (Text.isInfixOf "calendarView") =<< readIORef badTrace
  outputs <- readIORef results
  [ghcResult,mhsResult] <- pure outputs
  assert "GHC/MicroHs payload or fingerprint differs" (ghcResult == mhsResult)
  reader <- right (capturedReadSources TextType payload payload "MicrosoftGraph.Meetings.Read.artifact" sources)
  (readers,_) <- compileBoth temporary toolchain compiler "meeting-artifact" reader
  changes <- get "changes" ghcResult :: IO [Value]
  evidence <- get "value" (last changes) >>= get "evidence"
  forM_ readers $ \program -> do
    forM_ [Just evidence,Just (change ["payload"] (const (object ["tag" .= text "Truncated"])) evidence),Nothing] $ \stored -> do
      let respond _ "evidence" "read" _ = pure (tagged "Right" (maybe none (tagged "Some") stored),Bytes.empty)
          respond _ cap method _ = fail ("Reader called " ++ cap ++ "/" ++ method)
      (result,_,_) <- brokerWith Normal respond program (object ["arguments" .= text "id","snapshot" .= text "selected"])
      tag <- maybe (fail "Missing read result") (get "tag") result :: IO Text.Text
      assert "captured read result" (tag == if stored == Just evidence then "Right" else "Left")
  transcriptReader <- right (capturedReadSources TextType payload TextType "MicrosoftGraph.Meetings.Read.transcript" sources)
  (transcriptReaders,_) <- compileBoth temporary toolchain compiler "meeting-transcript" transcriptReader
  captured <- mapM (\c -> get "value" c >>= get "evidence") changes
  kinds <- mapM (\item -> do
    kind <- get "payload" item >>= get "value" >>= get "tag"
    pure (kind :: Text.Text,item)) captured
  transcriptEvidence <- maybe (fail "Missing transcript fixture") pure (lookup "Transcript" kinds)
  attendanceEvidence <- maybe (fail "Missing attendance fixture") pure (lookup "Attendance" kinds)
  ref <- get "payload" transcriptEvidence >>= get "value" >>= get "value" >>= get "content" :: IO Value
  let vtt = "WEBVTT\r\n\r\n00:00:01.000 --> 00:00:02.000\r\n<v Speaker>synthetic 雪 🦋</v>\r\n"
      found value = tagged "Right" (tagged "Some" value)
      unavailable = tagged "Left" (text "Captured evidence unavailable")
      truncated = change ["payload"] (const (object ["tag" .= text "Truncated"])) transcriptEvidence
      validBlob = (tagged "Right" (object []),Text.encodeUtf8 vtt)
      cases =
        [ ("VTT",found transcriptEvidence,validBlob,tagged "Right" (text vtt),True)
        , ("empty text",found transcriptEvidence,(tagged "Right" (object []),Bytes.empty),tagged "Right" (text ""),True)
        , ("unknown ID",tagged "Right" none,validBlob,tagged "Left" (text "No captured meeting artifact with that ID"),False)
        , ("truncated",found truncated,validBlob,tagged "Left" (text "Meeting artifact payload has been truncated"),False)
        , ("attendance",found attendanceEvidence,validBlob,tagged "Left" (text "Meeting artifact is an attendance report, not a transcript"),False)
        , ("evidence failure",unavailable,validBlob,unavailable,False)
        , ("missing blob",found transcriptEvidence,(tagged "Left" (text "Missing fixture blob"),Bytes.empty),tagged "Left" (text "Missing fixture blob"),True)
        , ("corrupt blob",found transcriptEvidence,(tagged "Left" (text "Corrupt fixture blob"),Bytes.empty),tagged "Left" (text "Corrupt fixture blob"),True)
        , ("invalid UTF-8",found transcriptEvidence,(tagged "Right" (object []),Bytes.pack [86,84,84,255]),tagged "Left" (text "Blob is not valid UTF-8 text"),True)
        ]
  forM_ transcriptReaders $ \program -> forM_ cases $ \(label,stored,blobReply,expected,readsBlob) -> do
    let respond raw "evidence" "read" args = do
          assert "evidence read has raw body" (Bytes.null raw)
          assert "transcript input ID lost" . (== ("transcript-id" :: Text.Text)) =<< get "id" args
          pure (stored,Bytes.empty)
        respond raw "blobs" "read" args = do
          assert "transcript read wrong blob or sent raw content" (Bytes.null raw && args == ref)
          pure blobReply
        respond _ _ _ _ = fail "Transcript reader requested a capability outside captured reads"
    (result,trace,status) <- brokerWith Normal respond program (object ["arguments" .= text "transcript-id","snapshot" .= text "selected"])
    assert (label ++ " transcript result differs") (status == ExitSuccess && result == Just expected)
    assert (label ++ " transcript capability trace differs") (trace == [("evidence","read")] ++ [("blobs","read") | readsBlob])
  putStrLn "Graph Meetings: windows, identity, capture-once, retention, failure paths, transcript text/refusals, local reads and GHC/MicroHs parity passed."

now :: Text.Text
now = "2026-10-20T12:00:00Z"
none :: Value
none = object ["tag" .= text "None"]
input :: Text.Text -> Maybe Text.Text -> Bool -> Value
input started since device = inputWithPrior started since device Nothing

inputWithPrior :: Text.Text -> Maybe Text.Text -> Bool -> Maybe Text.Text -> Value
inputWithPrior started since device previous = object ["arguments" .= object
  ["input" .= object ["config" .= object ["auth" .= auth,"retentionDays" .= text "30"],
    "options" .= maybe none (\s -> tagged "Some" (object ["since" .= tagged "Some" (text s)])) since],
    "startedAt" .= started,"priorPosition" .= maybe none (\t -> tagged "Some" (object ["lastSuccessfulFetch" .= t])) previous],"concurrency" .= ("4" :: String),"snapshot" .= text "selected"]
  where
    auth = if device then tagged "DeviceCode" (object ["tenant" .= text "tenant","clientId" .= text "client","tokenKey" .= text "key","scopes" .= (["User.Read"] :: [Text.Text])])
      else tagged "ClientSecret" (object ["tenant" .= text "tenant","clientId" .= text "client","secretKey" .= text "key"])

provider :: [(Text.Text,Value)] -> Text.Text -> IO (Bytes.ByteString -> String -> String -> Value -> IO (Value,Bytes.ByteString), IORef [Text.Text])
provider old scenario = do
  trace <- newIORef []
  attempts <- newIORef (0 :: Int)
  let respond raw capability method args = case (capability,method) of
        ("secrets","get") -> pure (tagged "Right" (text "secret"),Bytes.empty)
        ("waiting","seconds") -> modifyIORef' trace ("wait":) >> pure (object [],Bytes.empty)
        ("digest","text") -> do
          values <- right (parseEither parseJSON args)
          pure (toJSON (runPureEff (runContentDigest (Digest.digestText values))),Bytes.empty)
        ("evidence","list") -> pure (tagged "Right" (toJSON (map fst old)),Bytes.empty)
        ("evidence","read") -> do
          key <- get "id" args
          pure (tagged "Right" (maybe none (tagged "Some") (lookup key old)),Bytes.empty)
        ("blobs","store") -> do
          assert "blob bytes passed through guest" (Bytes.null raw)
          modifyIORef' trace ("blob":)
          url <- get "url" args :: IO Text.Text
          modifyIORef' trace (("blob-url:" <> url):)
          n <- readIORef attempts
          modifyIORef' attempts (+1)
          pure (downloadResult (Right (if scenario == "blob-failure" then BlobResponse 500 [] Nothing
            else if scenario == "content-denied" || scenario == "multi-fallback" && "/users/second-user/" `Text.isInfixOf` url then BlobResponse 403 [] Nothing
            else if n == 0 then BlobResponse 429 [("Retry-After","1")] Nothing
            else BlobResponse 200 [] (Just (BlobRef (Text.replicate 64 "a") 40 "text/vtt" (Just "transcript.vtt"))))),Bytes.empty)
        ("http","send") -> do
          url <- get "url" args :: IO Text.Text
          modifyIORef' trace (url:)
          let base :: Text.Text
              base = case Text.stripPrefix "https://graph.microsoft.com/v1.0/users/" url of
                Just rest -> "https://graph.microsoft.com/v1.0/users/" <> Text.takeWhile (/= '/') rest
                Nothing -> "https://graph.microsoft.com/v1.0/me"
              secondUser = "/users/second-user" `Text.isSuffixOf` base
              meetingId = if secondUser && scenario /= "multi-fallback" then "meeting-2" else "meeting-1"
              meeting = base <> "/onlineMeetings/" <> meetingId
              multi = scenario `elem` ["multi","multi-fallback","multi-alias","multi-supported"]
          if "login.microsoftonline.com" `Text.isInfixOf` url then pure (http 200 (object ["access_token" .= text "token"]))
          else if "/users?" `Text.isInfixOf` url then
            if scenario == "users-denied" then pure (http 403 (object []))
            else if scenario == "users-page-failure" && "page=2" `Text.isSuffixOf` url then pure (http 500 (object []))
            else if multi then pure (http 200 (object
              (["value" .= [directoryUser key | key <- if "page=2" `Text.isSuffixOf` url
                then ["policy-denied","no-mailbox","second-user","disabled"] else ["user-id","second-user","calendar-denied","guest"]]] ++
              ["@odata.nextLink" .= text "https://graph.microsoft.com/v1.0/users?page=2" | not ("page=2" `Text.isSuffixOf` url)])))
            else pure (http 200 (object (["value" .=
              (if scenario == "users-bad-enabled" then [object ["id" .= text "bad", "accountEnabled" .= text "true", "userType" .= text "Member"]]
               else if scenario == "users-missing-type" then [object ["id" .= text "bad", "accountEnabled" .= True]]
               else map directoryUser ["user-id","disabled","guest"]) ] ++
              ["@odata.nextLink" .= (if scenario == "users-foreign" then "https://other.example/users" else if scenario == "users-cycle" then url else "https://graph.microsoft.com/v1.0/users?page=2") |
                scenario `elem` ["users-page-failure","users-foreign","users-cycle"]])))
          else if "calendarView" `Text.isInfixOf` url then
            if scenario == "forbidden" || "/users/calendar-denied/" `Text.isInfixOf` url then pure (http 403 (object []))
            else if scenario == "unexpected-mailbox-error" then pure (http 404 (object ["error" .= object ["code" .= text "UnknownFailure"]]))
            else if "/users/no-mailbox/" `Text.isInfixOf` url then pure (http 404 (object ["error" .= object ["code" .= text (if scenario == "multi-alias" then "ErrorMailboxNotEnabledForRESTAPI" else if scenario == "multi-supported" then "MailboxNotSupportedForRESTAPI" else "MailboxNotEnabledForRESTAPI")]]))
            else pure (http 200 (object
              (["value" .= (if secondUser then
                [change ["isOrganizer"] (const (Bool False)) (event False), change ["onlineMeeting"] (const (object ["joinUrl" .= text "https://teams.example/second"])) (event False)]
                else [event (scenario == "unsupported"),event False,object ["isOnlineMeeting" .= False],future] ++ [badEvent | scenario `elem` ["missing-join","unresolved","ambiguous","missing-organizer","resolve-not-found"]])] ++
                ["@odata.nextLink" .= (base <> "/calendarView?page=2") | not ("page=2" `Text.isSuffixOf` url)])))
          else if "/users/policy-denied/onlineMeetings" `Text.isInfixOf` url then pure (http 403 (object []))
          else if scenario == "artifact-unauthorized" && "/transcripts" `Text.isSuffixOf` url then pure (http 401 (object []))
          else if scenario == "artifact-error" && "/attendanceReports" `Text.isSuffixOf` url then pure (http 500 (object []))
          else if scenario == "resolution-denied" && "onlineMeetings?$filter=" `Text.isInfixOf` url then pure (http 403 (object []))
          else if scenario == "transcripts-denied" && "/transcripts?page=2" `Text.isSuffixOf` url then pure (http 403 (object []))
          else if scenario == "reports-denied" && "/attendanceReports" `Text.isSuffixOf` url then pure (http 403 (object []))
          else if scenario == "records-denied" && "/attendanceRecords?page=2" `Text.isSuffixOf` url then pure (http 403 (object []))
          else if scenario == "transcript-not-found" && "/transcripts" `Text.isSuffixOf` url then pure (http 404 notFound)
          else if scenario == "report-not-found" && "/attendanceReports" `Text.isSuffixOf` url then pure (http 404 notFound)
          else if scenario == "records-not-found" && "/attendanceRecords" `Text.isInfixOf` url then pure (http 404 notFound)
          else if scenario == "resolve-late-not-found" && "/onlineMeetings?page=2" `Text.isSuffixOf` url then pure (http 404 notFound)
          else if "onlineMeetings?$filter=" `Text.isInfixOf` url then
            if scenario == "resolve-not-found-only" || scenario == "resolve-not-found" && "bad-meeting" `Text.isInfixOf` url then pure (http 404 notFound)
            else if scenario == "resolve-unknown-404" then pure (http 404 (object ["error" .= object ["code" .= text "UnknownFailure"]]))
            else if scenario == "resolve-late-not-found" then pure (http 200 (object ["value" .= [resolvedMeeting], "@odata.nextLink" .= (base <> "/onlineMeetings?page=2")]))
            else if scenario == "resolution-error" then pure (http 500 (object []))
            else pure (http 200 (collection (if scenario == "unresolved-only" then []
              else if "bad-meeting" `Text.isInfixOf` url then case scenario of
                "unresolved" -> []
                "ambiguous" -> [resolvedMeeting,resolvedMeeting]
                "missing-organizer" -> [change ["participants"] (const (object [])) resolvedMeeting]
                _ -> [resolvedMeeting]
              else [change ["id"] (const (text meetingId)) resolvedMeeting])))
          else if "/transcripts" `Text.isSuffixOf` url then pure (http 200 (object ["value" .= ([transcript "same"] ++ windowTranscripts),"@odata.nextLink" .=
            (if scenario == "foreign-page" then "https://other.example/transcripts" else meeting <> "/transcripts?page=2")]))
          else if "/transcripts?page=2" `Text.isSuffixOf` url then pure (http 200 (object
            (["value" .= ([transcript "second"] ++ [transcript "late" | scenario == "late"])] ++ ["@odata.nextLink" .= url | scenario == "cycle"])))
          else if "/attendanceReports" `Text.isSuffixOf` url then pure (http 200 (collection
            ([report "same" "2026-10-19T10:00:00Z" "2026-10-19T11:00:00Z", report "old" "2026-01-01T10:00:00Z" "2026-01-01T11:00:00Z"] ++ windowReports ++ capReports)))
          else if "/attendanceRecords" `Text.isInfixOf` url then
            if "page=2" `Text.isSuffixOf` url && scenario == "page-failure" then pure (http 500 (object []))
            else pure (http 200 (object (["value" .= [attendee]] ++ ["@odata.nextLink" .= (url <> "?page=2") | not ("page=2" `Text.isSuffixOf` url)])))
          else fail ("Unexpected URL: " ++ Text.unpack url)
        _ -> fail ("Unexpected capability " ++ capability ++ "/" ++ method)
  pure (respond,trace)
  where
    windowTimes :: [(Text.Text,Text.Text,Text.Text)]
    windowTimes =
      [("out-window-old","2026-01-01T10:00:00Z","2026-01-01T11:00:00Z"),
       ("out-window-straddle","2026-10-18T23:00:00Z","2026-10-19T01:00:00Z"),
       ("out-window-future","2026-10-21T10:00:00Z","2026-10-21T11:00:00Z"),
       ("out-window-ongoing","2026-10-20T11:00:00Z","2026-10-20T13:00:00Z"),
       ("lower","2026-10-19T00:00:00Z","2026-10-19T01:00:00Z"),
       ("upper","2026-10-20T12:00:00Z","2026-10-20T12:00:00Z")]
    windowTranscripts = [object ["id" .= key, "createdDateTime" .= start, "endDateTime" .= end]
      | (key,start,end) <- windowTimes, scenario == "artifact-window"]
    capReports = [report (Text.pack ("old-" ++ show i)) "2026-01-01T10:00:00Z" "2026-01-01T11:00:00Z"
      | i <- [1 .. (if scenario == "cap-49" then 47 else if scenario == "cap-50" then 48 else 0) :: Int]]
    windowReports = [report key start end | (key,start,end) <- windowTimes, scenario == "artifact-window"]
    notFound = object ["error" .= object ["code" .= text "NotFound"]]
    resolvedMeeting = object ["id" .= text "meeting-1","subject" .= text "Meeting 雪","participants" .= object
      ["organizer" .= object ["identity" .= object ["user" .= object ["id" .= text "organizer-id"]]]]]
    badEvent = change ["onlineMeeting"] (const (if scenario == "missing-join" then Null else object ["joinUrl" .= text "https://teams.example/bad-meeting"])) (event False)
    event unsupported = object ["id" .= text "event-id","isOnlineMeeting" .= True,"isOrganizer" .= True,"onlineMeetingProvider" .= text (if unsupported then "skypeForBusiness" else "teamsForBusiness"),
      "onlineMeeting" .= object ["joinUrl" .= text "https://teams.example/meet'a"], "end" .= object ["dateTime" .= text "2026-10-19T13:00:00.0000000","timeZone" .= text "UTC"]]
    future = object ["isOnlineMeeting" .= True,"isOrganizer" .= True, "end" .= object ["dateTime" .= text "2027-01-01T11:00:00","timeZone" .= text "UTC"]]
    transcript key = object ["id" .= text key,"createdDateTime" .= text (if key == "late" then "2026-10-20T11:01:00Z" else "2026-10-19T10:01:00Z"),"endDateTime" .= text (if scenario == "malformed-artifact" then "invalid" else "2026-10-19T11:00:00Z")]
    report key start end = object ["id" .= text key,"meetingStartDateTime" .= text start,"meetingEndDateTime" .= text end]
    attendee = object ["identity" .= object ["id" .= text "guest-id","displayName" .= text "Guest 雪","tenantId" .= Null, "@odata.type" .= text "#microsoft.graph.azureCommunicationServicesUserIdentity", "azureCommunicationServicesResourceId" .= text "acs-resource"],
      "emailAddress" .= text "guest@example.test", "role" .= text "Attendee", "totalAttendanceInSeconds" .= (60 :: Int),
      "attendanceIntervals" .= replicate 2 (object ["joinDateTime" .= text "2026-10-19T10:00:00Z","leaveDateTime" .= text "2026-10-19T10:00:30Z","durationInSeconds" .= (30 :: Int)])]

collection :: [Value] -> Value
collection values = object ["value" .= values]
http :: Int -> Value -> (Value,Bytes.ByteString)
http status body = (tagged "Right" (object ["status" .= Text.pack (show status),"headers" .= ([] :: [Value])]),Lazy.toStrict (encode body))
text :: Text.Text -> Value
text = String
tagged :: Text.Text -> Value -> Value
tagged tag value = object ["tag" .= tag,"value" .= value]
get :: FromJSON a => Key -> Value -> IO a
get key = either (fail . show) pure . parseEither (withObject "fixture" (.: key))
changesFrom :: Maybe Value -> IO [Value]
changesFrom result = maybe (fail "Missing result") (get "value") result >>= get "changes"
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)
change :: [Key] -> (Value -> Value) -> Value -> Value
change [] f value = f value
change (key:rest) f (Object fields) = case Map.lookup key fields of
  Just value -> Object (Map.insert key (change rest f value) fields)
  Nothing -> error "Missing fixture key"
change _ _ _ = error "Invalid fixture path"

-- Extra accounts must never cause a calendar request, even if they have calendars.
directoryUser :: Text.Text -> Value
directoryUser key = object ["id" .= key, "accountEnabled" .= (key /= "disabled"),
  "userType" .= (if key == "guest" then "Guest" else "Member" :: Text.Text)]
