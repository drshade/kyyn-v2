-- Generated Salesforce Query and login adapters under GHC and MicroHs. Recorded
-- providers cover exact JSON, complete snapshots, pagination failures, identities,
-- removals/restoration (including 3,000-row snapshots), local reads, credential
-- rotation, rejected refresh grants and device polling HTTP failures.
-- No live credentials or Salesforce calls.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Control.Monad (forM_, unless)
import Data.Aeson (Value(..), FromJSON, object, (.=), (.:), toJSON)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.Key as Key
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
import Kyyn.Plumbing.Protocol.PluginInvocation
import System.Directory (findExecutable)
import System.Environment (getEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.Info (compilerVersion)
import System.IO.Temp (withSystemTempDirectory)
import PluginFetchTests (compileBoth, brokerWith, Scenario(..))

main :: IO ()
main = withSystemTempDirectory "kyyn-salesforce-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  toolchain <- getEnv "KYYN_TEST_TOOLCHAIN"
  compiler <- findExecutable ("ghc-" ++ showVersion compilerVersion) >>= maybe (fail "Matching GHC required") pure
  scope <- right (directoryScope temporary)
  let directories = ["shared/kyyn-types/src","guest/kyyn-sdk/src","guest/kyyn-runtime/src","vendor/json","vendor/transformers","plugins/salesforce/src"]
      load folder = do
        root <- right (directoryScope (repo </> folder))
        runEff (runFailure (runFileSystemIO scope (readTree root))) >>= right
      inspect name = fmap fst <$> inspectDataType toolchain (map (repo </>) directories) name >>= right
  sources <- filter (isSuffixOf ".hs" . relativeName . fst) . concatMap files <$> mapM load directories
  config <- inspect "Salesforce.Query.Types.QueryConfig"
  payload <- inspect "Salesforce.Query.Types.Record"
  adapter <- right (acquisitionSources config payload Nothing "Salesforce.Query.fetch" sources)
  (programs,_) <- compileBoth temporary toolchain compiler "salesforce" adapter
  outputs <- newIORef []
  forM_ programs $ \program -> do
    (respond,trace) <- provider [] "normal"
    (result,_,status) <- brokerWith Normal respond program (input False)
    assert "fetch exit" (status == ExitSuccess)
    changes <- changesFrom result
    assert "initial snapshot" . (== ["New","New"]) =<< mapM tagOf changes
    stored <- mapM (\c -> do v <- get "value" c; (,) <$> get "id" v <*> get "evidence" v) changes
    (_,firstStored):_ <- pure stored
    body <- get "payload" firstStored >>= get "value" >>= get "json" :: IO Text.Text
    assert "decimal lost precision" ("12345678901234567890.1234567890123456789" `Text.isInfixOf` body)
    assert "nested fields lost" ("\"Owner\":{\"Name\":\"雪\",\"Nullable\":null}" `Text.isInfixOf` body)
    events <- readIORef trace
    assert "query encoding" (any (Text.isInfixOf "q=SELECT%20Id%2C%20Amount%20FROM%20Opportunity") events)
    modifyIORef' outputs (changes:)
    forM_ ["normal","reordered"] $ \scenario -> do
      (same,_) <- provider stored scenario
      (unchanged,_,_) <- brokerWith Normal same program (input False)
      assert "unchanged record emitted changes" . null =<< changesFrom unchanged
    (sameQuery,_) <- provider stored "normal"
    (changedSource,_,_) <- brokerWith Normal sameQuery program (object ["concurrency" .= text "4","arguments" .= set "query" (text "SELECT Id, Amount FROM Opportunity WHERE IsClosed = false") (configuration False),"snapshot" .= text "prior"])
    assert "query source reference change was ignored" . (== ["Updated","Updated"]) =<< (changesFrom changedSource >>= mapM tagOf)
    (changed,_) <- provider stored "changed"
    (updated,_,_) <- brokerWith Normal changed program (input False)
    assert "snapshot delta" . (== ["Updated","New","Removed"]) =<< (changesFrom updated >>= mapM tagOf)
    (empty,_) <- provider stored "empty"
    (removed,_,_) <- brokerWith Normal empty program (input False)
    assert "empty snapshot did not remove prior records" . (== ["Removed","Removed"]) =<< (changesFrom removed >>= mapM tagOf)
    let truncated = [(key,set "payload" (object ["tag" .= text "Truncated"]) value) | (key,value) <- stored]
    (restore,_) <- provider truncated "normal"
    (restored,_,_) <- brokerWith Normal restore program (input False)
    assert "truncated same-version restoration" . (== ["SetPayload","SetPayload"]) =<< (changesFrom restored >>= mapM tagOf)
    forM_ ["page-failure","foreign","cycle","duplicate-id","missing-id","numeric-id","blank-id","duplicate-key","missing-next","bad-count","bad-done","child-pages","auth-failure","empty-token","unauthorized","forbidden","throttle-exhausted"] $ \scenario -> do
      (bad,_) <- provider stored scenario
      (failed,_,_) <- brokerWith Normal bad program (input False)
      assert ("failure published a partial snapshot: " ++ Text.unpack scenario) . (== ("Left" :: Text.Text)) =<< maybe (fail "No result") (get "tag") failed
    (retry,retryTrace) <- provider [] "retry"
    (retried,_,_) <- brokerWith Normal retry program (input False)
    assert "retry did not complete" . (==2) . length =<< changesFrom retried
    assert "Retry-After not honored" . elem "wait:1" =<< readIORef retryTrace
    (device,deviceTrace) <- provider [] "normal"
    (refreshed,_,_) <- brokerWith Normal device program (input True)
    assert "refresh fetch" . (==2) . length =<< changesFrom refreshed
    assert "rotated token not saved" . elem "put:rotated" =<< readIORef deviceTrace
    (revoked,_) <- provider [] "auth-failure"
    (rejected,_,_) <- brokerWith Normal revoked program (input True)
    assert "revoked refresh token lacked login guidance" ("run connector login again" `Text.isInfixOf` Text.pack (show rejected))
    assert "provider credential leaked" (not ("secret-value" `Text.isInfixOf` Text.pack (show rejected)))
    (large,_) <- provider [] "large"
    (initialLarge,_,_) <- brokerWith Normal large program (input False)
    largeChanges <- changesFrom initialLarge
    assert "large initial count" (length largeChanges == 3000)
    largeStored <- mapM (\c -> do v <- get "value" c; (,) <$> get "id" v <*> get "evidence" v) largeChanges
    (shifted,_) <- provider (reverse largeStored) "large-shift"
    (shiftedResult,_,_) <- brokerWith Normal shifted program (input False)
    shiftedChanges <- changesFrom shiftedResult
    tags <- mapM tagOf shiftedChanges
    assert "large snapshot delta" (tags == replicate 1500 "New" ++ replicate 1500 "Removed")
    addedIds <- mapM (\c -> get "value" c >>= get "id") (take 1500 shiftedChanges)
    removedIds <- mapM (get "value") (drop 1500 shiftedChanges)
    assert "large new identities" (addedIds == map largeId [3000..4499])
    assert "large removed identities" (removedIds == map largeId [0..1499])
    forM_ [set "instanceUrl" (text "https://example.test/path") (configuration False),set "query" (text "DELETE FROM Account") (configuration False)] $ \invalid -> do
      (failed,_,_) <- brokerWith Normal (\_ _ _ _ -> fail "Invalid config called host") program (object ["concurrency" .= text "4","arguments" .= invalid,"snapshot" .= text "prior"])
      assert "invalid config accepted" . (== ("Left" :: Text.Text)) =<< maybe (fail "No result") (get "tag") failed
  results <- readIORef outputs
  [ghcResult,mhsResult] <- pure results
  assert "GHC/MicroHs evidence differs" (ghcResult == mhsResult)
  loginAdapter <- right (loginSources config "Salesforce.Query.Config.login" sources)
  (logins,_) <- compileBoth temporary toolchain compiler "salesforce-login" loginAdapter
  forM_ logins $ \program -> do
    (respond,trace) <- provider [] "normal"
    (result,_,_) <- brokerWith Normal respond program (configuration True)
    assert "device login" (result == Just (tagged "Right" (object [])))
    events <- readIORef trace
    assert "device polling/backoff/persistence" (reverse (filter (Text.isPrefixOf "wait:") events) == ["wait:1","wait:1","wait:6"] && "put:enrolled" `elem` events)
    (app,appTrace) <- provider [] "normal"
    (appResult,_,_) <- brokerWith Normal app program (configuration False)
    assert "client credentials login" (appResult == Just (tagged "Right" (object [])))
    assert "application token was persisted" . not . any (Text.isPrefixOf "put:") =<< readIORef appTrace
    forM_ ["declined","expired","empty-token","poll-html","poll-server-pending"] $ \scenario -> do
      (bad,badTrace) <- provider [] scenario
      (failed,_,_) <- brokerWith Normal bad program (configuration True)
      assert "failed login succeeded" . (== ("Left" :: Text.Text)) =<< maybe (fail "No result") (get "tag") failed
      if scenario == "poll-html" || scenario == "poll-server-pending" then do
        assert "poll failure lost HTTP status" ("HTTP 500" `Text.isInfixOf` Text.pack (show failed))
        waits <- filter (Text.isPrefixOf "wait:") <$> readIORef badTrace
        assert "server failure retried as pending" (waits == ["wait:1"])
      else pure ()
      assert "failed login wrote a token" . not . any (Text.isPrefixOf "put:") =<< readIORef badTrace
  reader <- right (capturedReadSources TextType payload payload "Salesforce.Query.Read.record" sources)
  (readers,_) <- compileBoth temporary toolchain compiler "salesforce-record" reader
  firstChange:_ <- pure ghcResult
  first <- get "value" firstChange >>= get "evidence"
  forM_ readers $ \program -> forM_ [Just first,Nothing] $ \stored -> do
    let respond _ "evidence" "read" _ = pure (tagged "Right" (maybe none (tagged "Some") stored),Bytes.empty)
        respond _ _ _ _ = fail "Captured record used network"
    (result,_,_) <- brokerWith Normal respond program (object ["arguments" .= text "a","snapshot" .= text "prior"])
    assert "captured read" . (== (if stored == Nothing then "Left" else "Right" :: Text.Text)) =<< maybe (fail "No result") (get "tag") result
  putStrLn "Salesforce: snapshots, pagination, exact JSON, identities, authentication and GHC/MicroHs parity passed."

configuration :: Bool -> Value
configuration device = object ["instanceUrl" .= text origin,"auth" .= auth,"apiVersion" .= text "v62.0",
  "query" .= text "SELECT Id, Amount FROM Opportunity","idField" .= text "Id"]
  where auth = tagged (if device then "DeviceCode" else "ClientSecret") (object ["clientId" .= text "client",(if device then "tokenKey" else "secretKey") .= text "secret"])
input :: Bool -> Value
input device = object ["concurrency" .= text "4","arguments" .= configuration device,"snapshot" .= text "prior"]
origin :: Text.Text
origin = "https://example.my.salesforce.com"

provider :: [(Text.Text,Value)] -> Text.Text -> IO (Bytes.ByteString -> String -> String -> Value -> IO (Value,Bytes.ByteString), IORef [Text.Text])
provider old scenario = do
  trace <- newIORef []
  polls <- newIORef (0 :: Int)
  attempts <- newIORef (0 :: Int)
  let oldMap = Map.fromList [(Key.fromText key,value) | (key,value) <- old]
      respond raw capability method args = case (capability,method) of
        ("secrets","get") -> pure (tagged "Right" (text "secret-value"),Bytes.empty)
        ("secrets","put") -> do value <- get "value" args; modifyIORef' trace (("put:" <> value):); pure (object [],Bytes.empty)
        ("waiting","seconds") -> do seconds <- get "seconds" args; modifyIORef' trace (("wait:" <> seconds):); pure (object [],Bytes.empty)
        ("login","display") -> pure (object [],Bytes.empty)
        ("digest","text") -> do values <- right (parseEither parseJSON args); pure (toJSON (runPureEff (runContentDigest (Digest.digestText values))),Bytes.empty)
        ("evidence","list") -> pure (tagged "Right" (toJSON (map fst old)),Bytes.empty)
        ("evidence","read") -> do key <- get "id" args; pure (tagged "Right" (maybe none (tagged "Some") (Map.lookup (Key.fromText key) oldMap)),Bytes.empty)
        ("http","send") -> do
          url <- get "url" args
          let body = Encoding.decodeUtf8 raw
          modifyIORef' trace (url:)
          assert "request left configured origin" ((origin <> "/") `Text.isPrefixOf` url)
          if "/token" `Text.isSuffixOf` url then
            if scenario == "auth-failure" then pure (http 400 [] "{\"error\":\"invalid_grant\",\"error_description\":\"secret-value\"}")
            else if scenario == "empty-token" then pure (http 200 [] "{\"access_token\":\"\"}")
            else if "response_type=device_code" `Text.isInfixOf` body then pure (http 200 [] "{\"device_code\":\"code\",\"user_code\":\"USER\",\"verification_uri\":\"https://example.my.salesforce.com/setup/connect\",\"interval\":1}")
            else if "grant_type=device" `Text.isInfixOf` body then do
              n <- readIORef polls; modifyIORef' polls (+1)
              pure (if scenario == "poll-html" then http 500 [] "<html>Unavailable</html>"
                else if scenario == "poll-server-pending" then http 500 [] "{\"error\":\"authorization_pending\"}"
                else if scenario == "declined" then http 400 [] "{\"error\":\"access_denied\"}"
                else if scenario == "expired" then http 400 [] "{\"error\":\"expired_token\"}"
                else if n == 0 then http 400 [] "{\"error\":\"authorization_pending\"}"
                else if n == 1 then http 400 [] "{\"error\":\"slow_down\"}"
                else http 200 [] "{\"access_token\":\"token\",\"refresh_token\":\"enrolled\"}")
            else pure (http 200 [] "{\"access_token\":\"token\",\"refresh_token\":\"rotated\"}")
          else do
            headers <- get "headers" args :: IO [Value]
            assert "query bearer token missing" (object ["name" .= text "Authorization","value" .= text "Bearer token"] `elem` headers)
            n <- readIORef attempts; modifyIORef' attempts (+1)
            let second = "/cursor-2" `Text.isSuffixOf` url
            pure (if scenario == "retry" && n == 0 || scenario == "throttle-exhausted" then http 429 [("Retry-After","1")] "{}"
              else if scenario == "unauthorized" then http 401 [] "{}"
              else if scenario == "forbidden" then http 403 [] "{}"
              else if scenario == "page-failure" && second then http 500 [] "{}"
              else http 200 [] (page scenario second))
        _ -> fail ("Unexpected capability " ++ capability ++ "/" ++ method)
  pure (respond,trace)

page :: Text.Text -> Bool -> Text.Text
page scenario second
  | scenario == "large" || scenario == "large-shift" =
      let start = (if scenario == "large-shift" then 1500 else 0) + (if second then 1500 else 0)
          records = Text.intercalate "," ["{\"Id\":\"" <> largeId n <> "\"}" | n <- [start..start+1499]]
      in "{\"totalSize\":3000,\"done\":" <> (if second then "true" else "false") <>
         ",\"records\":[" <> records <> "]" <>
         (if second then "" else ",\"nextRecordsUrl\":\"/services/data/v62.0/query/cursor-2\"") <> "}"
  | scenario == "empty" = "{\"records\":[],\"done\":true,\"totalSize\":0}"
  | otherwise = "{\"totalSize\":" <> (if scenario == "bad-count" then "3" else "2") <> ",\"done\":" <>
      (if scenario == "bad-done" then "null" else if second && scenario /= "cycle" then "true" else "false") <>
      ",\"records\":[" <> record <> "]" <>
      (if scenario == "missing-next" || second && scenario /= "cycle" then "" else ",\"nextRecordsUrl\":\"" <>
       (if scenario == "foreign" then "https://other.example/query" else "/services/data/v62.0/query/cursor-2") <> "\"") <> "}"
  where
    record | second = if scenario == "duplicate-id" then "{\"Id\":\"a\"}" else if scenario == "changed" then "{\"Id\":\"c\"}" else "{\"Id\":\"b\"}"
           | scenario == "missing-id" = "{}"
           | scenario == "numeric-id" = "{\"Id\":42}"
           | scenario == "blank-id" = "{\"Id\":\" \"}"
           | scenario == "duplicate-key" = "{\"Id\":\"a\",\"Id\":\"b\"}"
           | scenario == "child-pages" = "{\"Id\":\"a\",\"Children\":{\"done\":false,\"records\":[]}}"
           | scenario == "changed" = "{\"Id\":\"a\",\"Amount\":10}"
           | scenario == "reordered" = "{\"Owner\":{\"Nullable\":null,\"Name\":\"雪\"},\"Amount\":12345678901234567890.12345678901234567890,\"Id\":\"a\"}"
           | otherwise = "{\"Id\":\"a\",\"Amount\":12345678901234567890.1234567890123456789,\"Owner\":{\"Name\":\"雪\",\"Nullable\":null}}"
http :: Int -> [(Text.Text,Text.Text)] -> Text.Text -> (Value,Bytes.ByteString)
http status headers body = (tagged "Right" (object ["status" .= Text.pack (show status),"headers" .= toJSON [object ["name" .= k,"value" .= v] | (k,v) <- headers]]),Encoding.encodeUtf8 body)
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

largeId :: Int -> Text.Text
largeId n = "row-" <> Text.justifyRight 5 '0' (Text.pack (show n))
