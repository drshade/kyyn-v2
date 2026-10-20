-- Recorded Graph Files providers under GHC and MicroHs: recursive listings,
-- scope resolution, blob reuse, renames/removals, globs and failure atomicity.
-- No live credentials or provider calls.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Control.Monad (forM_, unless)
import Data.Aeson (Value(..), FromJSON, object, (.=), (.:), toJSON)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Map
import Data.Aeson.Types (parseEither, withObject, parseJSON)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Data.IORef
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
import Kyyn.Plumbing.Protocol.Blob (downloadResult)
import Kyyn.Types.Blob (BlobRef(..), BlobResponse(..))
import Kyyn.Plumbing.Protocol.PluginInvocation
import System.Directory (findExecutable)
import System.Environment (getEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.Info (compilerVersion)
import System.IO.Temp (withSystemTempDirectory)
import PluginFetchTests (compileBoth, brokerWith, Scenario(..))

main :: IO ()
main = withSystemTempDirectory "kyyn-graph-files-" $ \temporary -> do
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
  config <- inspect "MicrosoftGraph.Files.Types.FilesConfig"
  payload <- inspect "MicrosoftGraph.Files.Types.FilePayload"
  adapter <- right (acquisitionSources config payload Nothing "MicrosoftGraph.Files.fetch" sources)
  (programs,_) <- compileBoth temporary toolchain compiler "graph-files" adapter
  outputs <- newIORef []
  forM_ programs $ \program -> do
    (respond,trace) <- provider [] "normal"
    (result,_,status) <- brokerWith Normal respond program (input configuration)
    assert "fetch exit" (status == ExitSuccess)
    changes <- changesFrom result
    assert "initial files" . (== ["New","New"]) =<< mapM tagOf changes
    stored <- mapM (\c -> do v <- get "value" c; (,) <$> get "id" v <*> get "evidence" v) changes
    (_,firstStored):_ <- pure stored
    firstPayload <- get "payload" firstStored >>= get "value"
    assert "root relative path" . (== ("a.txt" :: Text.Text)) =<< get "path" firstPayload
    initialEvents <- readIORef trace
    assert "content download count" (length (filter (Text.isPrefixOf "blob:") initialEvents) == 2)
    modifyIORef' outputs (changes:)
    forM_ ["normal","renamed","changed","no-tag","empty","removed"] $ \scenario -> do
      (respondAgain,eventsRef) <- provider stored scenario
      (again,_,_) <- brokerWith Normal respondAgain program (input configuration)
      delta <- changesFrom again
      tags <- mapM tagOf delta
      let expected = case scenario of
            "renamed" -> ["Updated","Updated"]
            "changed" -> ["Updated"]
            "no-tag" -> ["Updated","Updated"]
            "empty" -> ["Removed","Removed"]
            "removed" -> ["Removed"]
            _ -> []
          downloads = case scenario of "changed" -> 1; "no-tag" -> 2; _ -> 0
      assert ("delta " ++ Text.unpack scenario) (tags == expected)
      events <- readIORef eventsRef
      assert ("content reuse " ++ Text.unpack scenario) (length (filter (Text.isPrefixOf "blob:") events) == downloads)
      if scenario == "renamed" then do
        paths <- mapM (\v -> get "value" v >>= get "evidence" >>= get "payload" >>= get "value" >>= get "path") delta
        assert "renamed folder descendants" (paths == ["renamed.txt","renamed-folder/b.txt" :: Text.Text])
      else pure ()
    let truncated = [(key,set "payload" (object ["tag" .= text "Truncated"]) value) | (key,value) <- stored]
    (restore,restoreTrace) <- provider truncated "normal"
    (restored,_,_) <- brokerWith Normal restore program (input configuration)
    assert "truncated restore" . (== ["SetPayload","SetPayload"]) =<< (changesFrom restored >>= mapM tagOf)
    assert "truncated content not fetched" . (==2) . length . filter (Text.isPrefixOf "blob:") =<< readIORef restoreTrace
    forM_ ["page-failure","foreign","cycle","missing-root","malformed-item","missing-size","bad-size","download-failure"] $ \scenario -> do
      (bad,_) <- provider stored scenario
      (failed,_,_) <- brokerWith Normal bad program (input configuration)
      assert ("partial listing published: " ++ Text.unpack scenario) . (== ("Left" :: Text.Text)) =<< maybe (fail "No failure") (get "tag") failed
    forM_ ["duplicate","folder-cycle","shortcut","package"] $ \scenario -> do
      (skip,_) <- provider stored scenario
      (skipped,_,_) <- brokerWith Normal skip program (input configuration)
      assert ("duplicate/unsupported item handling: " ++ Text.unpack scenario) . (== ["Removed"]) =<< (changesFrom skipped >>= mapM tagOf)
    forM_ [("*.txt",1),("**/*.txt",2),("folder/?.txt",1),("**/a.txt",1),("**/b.txt",1),("**/txt",0)] $ \(pattern,count) -> do
      (filtered,_) <- provider [] "normal"
      (resultFiltered,_,_) <- brokerWith Normal filtered program (input (set "includeGlobs" (toJSON [pattern :: Text.Text]) configuration))
      assert ("glob " ++ Text.unpack pattern) . (==count) . length =<< changesFrom resultFiltered
    forM_ [tagged "OneDrive" (object ["user" .= text "me"]),tagged "SharedUrl" (object ["url" .= text "https://example.sharepoint.com/:f:/雪"])] $ \scopeValue -> do
      (resolve,resolveTrace) <- provider [] "normal"
      (resolved,_,_) <- brokerWith Normal resolve program (input (set "scope" scopeValue configuration))
      assert "scope resolution" . (==2) . length =<< changesFrom resolved
      if scopeValue == tagged "SharedUrl" (object ["url" .= text "https://example.sharepoint.com/:f:/雪"]) then
        assert "sharing URL UTF-8/base64url encoding" . elem "https://graph.microsoft.com/v1.0/shares/u!aHR0cHM6Ly9leGFtcGxlLnNoYXJlcG9pbnQuY29tLzpmOi_pm6o/driveItem" =<< readIORef resolveTrace
      else pure ()
    (single,_) <- provider [] "normal"
    (singleResult,_,_) <- brokerWith Normal single program (input (set "itemPath" (text "a.txt") configuration))
    assert "single file" . (==1) . length =<< changesFrom singleResult
    forM_ [set "itemPath" (text "../bad") configuration,set "includeGlobs" (toJSON ["a//b" :: Text.Text]) configuration] $ \invalid -> do
      (failed,_,_) <- brokerWith Normal (\_ _ _ _ -> fail "Invalid config called host") program (input invalid)
      assert "invalid config accepted" . (== ("Left" :: Text.Text)) =<< maybe (fail "No result") (get "tag") failed
  [ghcResult,mhsResult] <- readIORef outputs
  assert "GHC/MicroHs evidence differs" (ghcResult == mhsResult)
  reader <- right (capturedReadSources TextType payload payload "MicrosoftGraph.Files.Read.file" sources)
  (readers,_) <- compileBoth temporary toolchain compiler "graph-file-read" reader
  firstChange:_ <- pure ghcResult
  first <- get "value" firstChange >>= get "evidence"
  forM_ readers $ \program -> do
    let respond _ "evidence" "read" _ = pure (tagged "Right" (tagged "Some" first),Bytes.empty)
        respond _ _ _ _ = fail "Captured file read used network"
    (result,_,_) <- brokerWith Normal respond program (object ["arguments" .= text "drive/a","snapshot" .= text "prior"])
    assert "captured file read" . (== ("Right" :: Text.Text)) =<< maybe (fail "No result") (get "tag") result
  putStrLn "Graph Files: recursive snapshots, scopes, blob reuse, failures and compiler parity passed."

configuration :: Value
configuration = object ["auth" .= tagged "ClientSecret" (object ["tenant" .= text "tenant","clientId" .= text "client","secretKey" .= text "secret"]),
  "scope" .= tagged "SiteLibrary" (object ["site" .= text "site","library" .= text "Documents"]),
  "itemPath" .= text "", "includeGlobs" .= ([] :: [Value])]
input :: Value -> Value
input config = object ["arguments" .= config,"snapshot" .= text "prior"]

provider :: [(Text.Text,Value)] -> Text.Text -> IO (Bytes.ByteString -> String -> String -> Value -> IO (Value,Bytes.ByteString), IORef [Text.Text])
provider old scenario = do
  trace <- newIORef []
  let respond _ capability method args = case (capability,method) of
        ("secrets","get") -> pure (tagged "Right" (text "secret-value"),Bytes.empty)
        ("digest","text") -> do values <- right (parseEither parseJSON args); pure (toJSON (runPureEff (runContentDigest (Digest.digestText values))),Bytes.empty)
        ("evidence","list") -> pure (tagged "Right" (toJSON (reverse (map fst old))),Bytes.empty)
        ("evidence","read") -> do key <- get "id" args; pure (tagged "Right" (maybe none (tagged "Some") (lookup key old)),Bytes.empty)
        ("blobs","store") -> do
          url <- get "url" args
          assert "download must use authenticated Graph endpoint" ("https://graph.microsoft.com/v1.0/drives/drive/items/" `Text.isPrefixOf` url)
          headers <- get "headers" args :: IO [Value]
          assert "download auth missing" (object ["name" .= text "Authorization","value" .= text "Bearer token"] `elem` headers)
          modifyIORef' trace (("blob:" <> url):)
          let digest = if scenario == "changed" then "b" else "a"
          pure (downloadResult (Right (if scenario == "download-failure" then BlobResponse 500 [] Nothing
            else BlobResponse 200 [] (Just (BlobRef (Text.replicate 64 digest) 3 "text/plain" Nothing)))),Bytes.empty)
        ("http","send") -> do
          url <- get "url" args
          modifyIORef' trace (url:)
          if "login.microsoftonline.com" `Text.isInfixOf` url then pure (http 200 "{\"access_token\":\"token\"}")
          else do
            assert "credentials left Graph" ("https://graph.microsoft.com/v1.0/" `Text.isPrefixOf` url)
            let second = "page=2" `Text.isSuffixOf` url
                endpoint = "https://graph.microsoft.com/v1.0/drives/drive/items/root/children"
            pure $
              if "/sites/site/drives" `Text.isSuffixOf` url then http 200 "{\"value\":[{\"id\":\"drive\",\"name\":\"Documents\"}]}"
              else if "/items/root:/a.txt" `Text.isSuffixOf` url then http 200 (fileValue scenario "a")
              else if "/items/folder/children" `Text.isSuffixOf` url then http 200 ("{\"value\":[" <> fileValue scenario "b" <> "]}")
              else if "/children" `Text.isSuffixOf` url || second then
                if scenario == "page-failure" && second then http 500 "{}"
                else if scenario == "empty" then http 200 "{\"value\":[]}"
                else if second then http 200 ("{\"value\":[" <> (if scenario == "removed" then "" else if scenario == "duplicate" then fileValue scenario "a" else folderValue scenario) <> "]}")
                else http 200 ("{\"value\":[" <> fileValue scenario "a" <> "],\"@odata.nextLink\":\"" <>
                  (if scenario == "foreign" then "https://example.invalid/private" else if scenario == "cycle" then endpoint else endpoint <> "?page=2") <> "\"}")
              else if scenario == "missing-root" then http 404 "{}"
              else if "/root" `Text.isSuffixOf` url || "/driveItem" `Text.isSuffixOf` url then
                http 200 "{\"id\":\"root\",\"name\":\"root\",\"parentReference\":{\"driveId\":\"drive\"},\"folder\":{}}"
              else http 500 "{}"
        _ -> fail ("Unexpected capability " ++ capability ++ "/" ++ method)
  pure (respond,trace)

fileValue :: Text.Text -> Text.Text -> Text.Text
fileValue scenario key
  | scenario == "malformed-item" = "null"
  | otherwise =
  "{\"id\":\"" <> key <> "\",\"name\":\"" <> (if scenario == "renamed" && key == "a" then "renamed" else key) <> ".txt\"," <>
  "\"webUrl\":\"https://example.sharepoint.com/" <> key <> "\",\"file\":{\"mimeType\":\"text/plain\"}," <>
  (if scenario == "missing-size" then "" else "\"size\":" <> (if scenario == "bad-size" then "4" else "3") <> ",") <>
  (if scenario == "no-tag" || scenario == "download-failure" then "" else "\"cTag\":\"" <> (if scenario == "changed" && key == "a" then "v2" else "v1") <> "\",") <>
  "\"lastModifiedDateTime\":\"2026-10-20T12:00:00Z\",\"lastModifiedBy\":{\"application\":{\"displayName\":\"Automation\"}}}"
folderValue :: Text.Text -> Text.Text
folderValue scenario
  | scenario == "shortcut" = "{\"id\":\"shortcut\",\"name\":\"Shortcut\",\"remoteItem\":{}}"
  | scenario == "package" = "{\"id\":\"notebook\",\"name\":\"Notebook\",\"package\":{}}"
  | otherwise = "{\"id\":\"" <> (if scenario == "folder-cycle" then "root" else "folder") <>
      "\",\"name\":\"" <> (if scenario == "renamed" then "renamed-folder" else "folder") <> "\",\"folder\":{}}"

http :: Int -> Text.Text -> (Value,Bytes.ByteString)
http status body = (tagged "Right" (object ["status" .= Text.pack (show status),"headers" .= ([] :: [Value])]),Encoding.encodeUtf8 body)
none :: Value
none = object ["tag" .= text "None"]
text :: Text.Text -> Value
text = String
tagged :: Text.Text -> Value -> Value
tagged tag value = object ["tag" .= tag,"value" .= value]
get :: FromJSON a => Key -> Value -> IO a
get key = either (fail . show) pure . parseEither (withObject "fixture" (.: key))
changesFrom :: Maybe Value -> IO [Value]
changesFrom result = maybe (fail "No result") (get "value") result
set :: Key -> Value -> Value -> Value
set key value (Object fields) = Object (Map.insert key value fields)
set _ _ value = value
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)

tagOf :: Value -> IO Text.Text
tagOf = get "tag"

