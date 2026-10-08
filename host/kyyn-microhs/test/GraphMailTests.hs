-- Real generated Mail adapters under GHC/MicroHs, with recorded Graph and blob
-- responses. No credentials or live provider. Covers folder-order deduplication,
-- capture-once, payload retention, attachments, throttling, reset boundaries,
-- pagination, initial-option rejection and failed acquisition. Set
-- KYYN_MAIL_BENCHMARK=1 for 2,000 retained 4-KiB payload reads per compiler.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Control.Monad (forM_, unless, when)
import Data.Aeson (Value(..), FromJSON, object, (.=), (.:), encode, toJSON)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Map
import Data.Aeson.Types (parseEither, withObject, parseJSON)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import Data.IORef (IORef, newIORef, readIORef, modifyIORef')
import Data.List (isSuffixOf)
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
import System.Environment (getEnv, lookupEnv)
import GHC.Clock (getMonotonicTimeNSec)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.Info (compilerVersion)
import System.IO.Temp (withSystemTempDirectory)
import PluginFetchTests (compileBoth, brokerWith, Scenario(..))

main :: IO ()
main = withSystemTempDirectory "kyyn-graph-mail-" $ \temporary -> do
  assert "native UTF-8 content digests differ from SHA-256 vectors"
    (runPureEff (runContentDigest (Digest.digestText ["", "abc"])) ==
      ["e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"])
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
  config <- inspect "MicrosoftGraph.Mail.Types.MailConfig"
  payload <- inspect "MicrosoftGraph.Mail.Types.Message"
  options <- inspect "MicrosoftGraph.Mail.Types.MailFetch"
  position <- inspect "MicrosoftGraph.Mail.Types.MailPosition"
  adapter <- right (statefulAcquisitionSources config payload (Just options) position "MicrosoftGraph.Mail.fetch" sources)
  (programs,_) <- compileBoth temporary toolchain compiler "mail" adapter
  benchmark <- (== Just "1") <$> lookupEnv "KYYN_MAIL_BENCHMARK"
  results <- newIORef []
  forM_ programs $ \program -> do
    (respond,trace) <- provider Nothing False
    (result,_,status) <- brokerWith Normal respond program (input "2026-10-08T12:00:00Z" False)
    assert "mail acquisition failed" (status == ExitSuccess)
    output <- maybe (fail "Mail produced no output") pure result >>= get "value"
    changes <- get "changes" output :: IO [Value]
    assert "cross-folder duplicate wasn't deduplicated" (length changes == 1)
    [firstChange] <- pure changes
    evidence <- get "value" firstChange >>= get "evidence"
    captured <- get "payload" evidence >>= get "value"
    assert "configured folder order lost" . (== ("z-sent" :: Text.Text)) =<< get "firstSeenFolder" captured
    assert "body changed" . (== ("Hello 雪\nquoted correspondence" :: Text.Text)) =<< get "body" captured
    attachments <- get "attachments" captured :: IO [Value]
    assert "attachment metadata lost" (length attachments == 2)
    link <- get "content" (attachments !! 1) >>= get "value" :: IO Text.Text
    assert "link invented cloud target URL" (link == base <> "/messages/message-1/attachments/link-1")
    events <- readIORef trace
    assert "retry or capture dedup failed" (length (filter (== "download") events) == 2 && length (filter (== "message") events) == 1)
    modifyIORef' results (output:)
    when benchmark $ do
      let bulkEvidence = change ["payload","value","body"] (const (String (Text.replicate 4096 "x"))) evidence
      (bulk,_) <- provider (Just bulkEvidence) False
      let respondBulk raw "evidence" "list" _ = pure
            (tagged "Right" (toJSON ["message-" <> show n | n <- [1 :: Int ..2000]]), raw)
          respondBulk raw capability method args = bulk raw capability method args
      start <- getMonotonicTimeNSec
      (bulkResult,_,_) <- brokerWith Normal respondBulk program (input "2026-10-08T12:00:00Z" True)
      assert "retained-payload benchmark changed evidence" . null =<< changesFrom bulkResult
      end <- getMonotonicTimeNSec
      putStrLn ("Mail retained 2000 x 4KiB payload scan: " <> show (fromIntegral (end-start) / 1e9 :: Double) <> " seconds")
    (again,againTrace) <- provider (Just evidence) False
    (repeated,_,_) <- brokerWith Normal again program (input "2026-10-08T12:00:00Z" True)
    assert "capture-once produced changes" . null =<< changesFrom repeated
    assert "capture-once downloaded again" . not . elem "download" =<< readIORef againTrace
    (expired,_,_) <- brokerWith Normal again program (input "2026-12-08T12:00:00Z" True)
    truncated <- changesFrom expired
    assert "retention deleted evidence" (length truncated == 1)
    [availabilityChange] <- pure truncated
    assert "retention not availability-only" . (== ("SetPayload" :: String)) =<< get "tag" availabilityChange
    (refusing,_) <- provider Nothing True
    (failed,_,_) <- brokerWith Normal refusing program (input "2026-10-08T12:00:00Z" False)
    assert "attachment failure published partial result" . (== ("Left" :: String)) =<< maybe (fail "Missing failure") (get "tag") failed
    (reset,resetTrace) <- provider (Just evidence) False
    let resetInput = change ["arguments","priorPosition","value","folders"]
          (const (toJSON [object ["folderId" .= text "z-sent", "since" .= text "2020-01-01T00:00:00Z",
            "deltaLink" .= (base <> "/mailFolders/z-sent/messages/delta?cursor=expired")]]))
          (input "2026-10-08T12:00:00Z" True)
    (resetResult,_,_) <- brokerWith Normal reset program resetInput
    assert "delta reset recaptured existing message" . null =<< changesFrom resetResult
    resetEvents <- readIORef resetTrace
    assert "delta reset lost original backfill boundary"
      (any (isSuffixOf "receivedDateTime%20ge%202020-01-01T00%3A00%3A00Z") resetEvents)
    let withBoundary = change ["arguments","input","options"]
          (const (tagged "Some" (object ["since" .= tagged "Some" (text "2020-01-01T00:00:00Z")])))
          (input "2026-10-08T12:00:00Z" True)
    (rejected,_,_) <- brokerWith Normal (\_ _ _ _ -> fail "continued since reached host capability") program withBoundary
    assert "continued since not refused" . (== ("Left" :: String)) =<< maybe (fail "Missing failure") (get "tag") rejected
  outputs <- readIORef results
  [ghcResult,mhsResult] <- pure outputs
  assert ("GHC/MicroHs payload or fingerprint differed: " <> show (ghcResult, mhsResult)) (ghcResult == mhsResult)
  [first] <- get "changes" ghcResult
  evidence <- get "value" first >>= get "evidence"
  reader <- right (capturedReadSources TextType payload TextType "MicrosoftGraph.Mail.Read.body" sources)
  (readers,_) <- compileBoth temporary toolchain compiler "mail-body" reader
  forM_ readers $ \program -> do
    forM_ [Just evidence, Just (change ["payload"] (const (object ["tag" .= text "Truncated"])) evidence), Nothing] $ \stored -> do
      let onlyReads _ "evidence" "read" _ = pure
            (tagged "Right" (maybe (object ["tag" .= text "None"]) (tagged "Some") stored), Bytes.empty)
          onlyReads _ capability method _ = fail ("Captured reader requested " <> capability <> "/" <> method)
      (result,_,_) <- brokerWith Normal onlyReads program (object ["arguments" .= text "message-1", "snapshot" .= text "selected"])
      value <- maybe (fail "Missing captured read result") pure result
      if stored == Just evidence
        then assert "captured body reader changed text" (value == tagged "Right" (text "Hello 雪\nquoted correspondence"))
        else assert "missing/truncated payload didn't fail" . (== ("Left" :: String)) =<< get "tag" value
  putStrLn "Graph Mail: capture-once, folder-order dedup, text/attachments, retries, retention and GHC/MicroHs fingerprint parity passed."

base :: Text.Text
base = "https://graph.microsoft.com/v1.0/users/me%40example.test"

input :: Text.Text -> Bool -> Value
input started continuing = object ["arguments" .= object
  ["input" .= object ["config" .= object
    ["auth" .= tagged "ClientSecret" (object ["tenant" .= text "tenant","clientId" .= text "client","secretKey" .= text "key"]),
     "mailbox" .= text "me@example.test","folders" .= [tagged "WellKnownFolder" (text "sentitems"),tagged "WellKnownFolder" (text "inbox")],"retentionDays" .= text "30"],
     "options" .= object ["tag" .= text "None"]],"startedAt" .= started,"priorPosition" .=
      (if continuing then tagged "Some" (object ["folders" .= [object ["folderId" .= f,"since" .= text "2026-09-08T12:00:00Z","deltaLink" .= (base <> "/mailFolders/" <> f <> "/messages/delta?cursor=1")] | f <- ["z-sent","a-inbox" :: Text.Text]]])
       else object ["tag" .= text "None"])],"snapshot" .= text "selected"]

provider :: Maybe Value -> Bool -> IO (Bytes.ByteString -> String -> String -> Value -> IO (Value,Bytes.ByteString), IORef [String])
provider old failing = do
  trace <- newIORef []
  attempts <- newIORef (0 :: Int)
  let respond raw capability method args = case (capability,method) of
        ("secrets","get") -> pure (tagged "Right" (text "fixture-secret"),Bytes.empty)
        ("waiting","seconds") -> pure (object [],Bytes.empty)
        ("digest","text") -> do
          values <- right (parseEither parseJSON args)
          pure (toJSON (runPureEff (runContentDigest (Digest.digestText values))),Bytes.empty)
        ("evidence","list") -> pure (tagged "Right" (toJSON (["message-1" :: String | Just _ <- [old]])),Bytes.empty)
        ("evidence","read") -> pure (tagged "Right" (maybe (object ["tag" .= text "None"]) (tagged "Some") old),Bytes.empty)
        ("blobs","store") -> do
          assert "blob request carried bytes" (Bytes.null raw)
          modifyIORef' trace ("download":)
          n <- readIORef attempts
          modifyIORef' attempts (+1)
          pure (downloadResult (Right (if failing then BlobResponse 500 [] Nothing
            else if n == 0 then BlobResponse 429 [("Retry-After","1")] Nothing
            else BlobResponse 200 [] (Just (BlobRef (Text.replicate 64 "a") 3 "application/test" (Just "test.bin"))))),Bytes.empty)
        ("http","send") -> do
          url <- get "url" args :: IO Text.Text
          modifyIORef' trace (Text.unpack url:)
          if "login.microsoftonline.com" `Text.isInfixOf` url then pure (http (object ["access_token" .= text "token"])) else do
            headers <- get "headers" args :: IO [Value]
            values <- mapM (get "value") headers :: IO [Text.Text]
            assert "immutable preference lost" (any (Text.isInfixOf "ImmutableId") values)
            if "cursor=expired" `Text.isSuffixOf` url then pure
              (tagged "Right" (object ["status" .= text "410", "headers" .= ([] :: [Value])]), "{}")
            else if "/messages/delta" `Text.isInfixOf` url then pure (http (object
              (["value" .= [object ["id" .= text "message-1"],object ["id" .= text "gone","@removed" .= object []]]] ++
               [if "page=2" `Text.isSuffixOf` url
                then "@odata.deltaLink" .= (Text.takeWhile (/= '?') url <> "?cursor=1")
                else "@odata.nextLink" .= (Text.takeWhile (/= '?') url <> "?page=2") ])))
            else if "/attachments?" `Text.isInfixOf` url then pure (http (object ["value" .=
              [attachment "fileAttachment" "file-1",attachment "referenceAttachment" "link-1"]]))
            else if "/messages/message-1?" `Text.isInfixOf` url then do
              modifyIORef' trace ("message":)
              pure (http (object ["subject" .= text "Subject","sentDateTime" .= text "2026-10-01T10:00:00Z",
                "receivedDateTime" .= text "2026-10-01T10:00:00Z","body" .= object ["contentType" .= text "text","content" .= text "Hello 雪\nquoted correspondence"]]))
            else if "/mailFolders/sentitems?" `Text.isInfixOf` url then pure (http (object ["id" .= text "z-sent"]))
            else if "/mailFolders/inbox?" `Text.isInfixOf` url then pure (http (object ["id" .= text "a-inbox"]))
            else fail ("Unexpected Graph request " ++ Text.unpack url)
        _ -> fail ("Unexpected capability " ++ capability ++ "/" ++ method)
  pure (respond,trace)
  where
    attachment kind key = object ["@odata.type" .= ("#microsoft.graph." <> kind :: Text.Text),"id" .= (key :: Text.Text),
      "name" .= text "test.bin","contentType" .= text "application/test","size" .= (3 :: Int),"isInline" .= True]

http :: Value -> (Value,Bytes.ByteString)
http body = (tagged "Right" (object ["status" .= text "200","headers" .= ([] :: [Value])]),Lazy.toStrict (encode body))
text :: Text.Text -> Value
text = String
tagged :: Text.Text -> Value -> Value
tagged tag value = object ["tag" .= tag,"value" .= value]
get :: FromJSON a => Key -> Value -> IO a
get key = either (fail . show) pure . parseEither (withObject "fixture" (.: key))
changesFrom :: Maybe Value -> IO [Value]
changesFrom result = maybe (fail "Missing result") (get "value") result >>= get "changes" :: IO [Value]
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)

change :: [Key] -> (Value -> Value) -> Value -> Value
change [] f value = f value
change (key:rest) f (Object fields) = case Map.lookup key fields of
  Just value -> Object (Map.insert key (change rest f value) fields)
  Nothing -> error ("Missing fixture key: " <> show key)
change _ _ value = error ("Bad fixture path: " <> show value)
