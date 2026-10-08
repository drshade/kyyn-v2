-- Real generated Mail adapters under GHC/MicroHs, with recorded Graph and blob
-- responses. No credentials or live provider. Covers folder-order deduplication,
-- capture-once, payload retention, attachments, throttling and failed acquisition.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Control.Monad (forM_, unless)
import Data.Aeson (Value(..), FromJSON, object, (.=), (.:), encode, toJSON)
import Data.Aeson.Key (Key)
import Data.Aeson.Types (parseEither, withObject, parseJSON)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import Data.IORef (IORef, newIORef, readIORef, modifyIORef')
import Data.List (isSuffixOf)
import Data.Version (showVersion)
import Effectful (runEff, runPureEff)
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
main = withSystemTempDirectory "kyyn-graph-mail-" $ \temporary -> do
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
  outputs <- readIORef results
  [ghcResult,mhsResult] <- pure outputs
  assert ("GHC/MicroHs payload or fingerprint differed: " <> show (ghcResult, mhsResult)) (ghcResult == mhsResult)
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
          if "login.microsoftonline.com" `Text.isInfixOf` url then pure (http (object ["access_token" .= text "token"])) else do
            headers <- get "headers" args :: IO [Value]
            values <- mapM (get "value") headers :: IO [Text.Text]
            assert "immutable preference lost" (any (Text.isInfixOf "ImmutableId") values)
            if "/messages/delta" `Text.isInfixOf` url then pure (http (object
              ["value" .= [object ["id" .= text "message-1"],object ["id" .= text "gone","@removed" .= object []]],
               "@odata.deltaLink" .= (Text.takeWhile (/= '?') url <> "?cursor=1")]))
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
