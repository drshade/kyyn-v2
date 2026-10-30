-- Recorded Directory snapshots under GHC and MicroHs: ordering, changes, nulls,
-- delegated/application auth, pagination failures and captured reads. No live calls.
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
import Kyyn.Plumbing.Protocol.PluginInvocation
import System.Directory (findExecutable)
import System.Environment (getEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.Info (compilerVersion)
import System.IO.Temp (withSystemTempDirectory)
import PluginFetchTests (compileBoth, brokerWith, Scenario(..))

main :: IO ()
main = withSystemTempDirectory "kyyn-graph-directory-" $ \temporary -> do
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
  config <- inspect "MicrosoftGraph.Directory.Types.DirectoryConfig"
  payload <- inspect "MicrosoftGraph.Directory.Types.DirectoryPayload"
  adapter <- right (acquisitionSources config payload Nothing "MicrosoftGraph.Directory.fetch" sources)
  (programs,_) <- compileBoth temporary toolchain compiler "graph-directory" adapter
  outputs <- newIORef []
  forM_ programs $ \program -> do
    (respond,trace) <- provider Nothing "normal"
    (result,_,status) <- brokerWith Normal respond program (input configuration)
    assert "fetch exit" (status == ExitSuccess)
    initial <- changesFrom result
    assert "one snapshot" . (== ["New"]) =<< mapM tagOf initial
    first <- case initial of [value] -> pure value; _ -> fail "Expected snapshot"
    stored <- get "value" first >>= get "evidence"
    users <- get "payload" stored >>= get "value" >>= get "users" :: IO [Value]
    assert "sorted users" . (== ["a","b"]) =<< mapM (get "id" :: Value -> IO Text.Text) users
    guest:_ <- pure users
    assert "disabled guest retained" . (== ("Guest" :: Text.Text)) =<< (get "userType" guest >>= get "value")
    assert "disabled value" . (== False) =<< (get "accountEnabled" guest >>= get "value")
    assert "null preserved" . (== ("None" :: Text.Text)) =<< (get "mail" guest >>= get "tag")
    assert "two pages" . (==2) . length =<< readIORef trace
    modifyIORef' outputs (initial:)
    forM_ [("normal",[]),("reordered",[]),("changed",["Updated"]),("added",["Updated"]),("removed",["Updated"]),("empty",["Updated"]),("null-enabled",["Updated"])] $ \(scenario,expected) -> do
      (repeatFetch,_) <- provider (Just stored) scenario
      (repeated,_,_) <- brokerWith Normal repeatFetch program (input configuration)
      assert ("delta " ++ Text.unpack scenario) . (==expected) =<< (changesFrom repeated >>= mapM tagOf)
    (restore,_) <- provider (Just (set "payload" (object ["tag" .= text "Truncated"]) stored)) "normal"
    (restored,_,_) <- brokerWith Normal restore program (input configuration)
    assert "restore" . (== ["SetPayload" :: Text.Text]) =<< (changesFrom restored >>= mapM tagOf)
    forM_ ["denied","late-denied","late-failure","foreign","cycle","duplicate","missing","bad-type","empty-id","malformed"] $ \scenario -> do
      (bad,_) <- provider (Just stored) scenario
      (failed,_,_) <- brokerWith Normal bad program (input configuration)
      assert ("failed snapshot: " ++ Text.unpack scenario) . (== ("Left" :: Text.Text)) =<< maybe (fail "No failure") (get "tag") failed
    (delegated,_) <- provider Nothing "normal"
    (delegatedResult,_,_) <- brokerWith Normal delegated program (input (set "auth" (device "https://graph.microsoft.com/User.Read.All") configuration))
    assert "credential modes agree" . (==initial) =<< changesFrom delegatedResult
    (invalid,_,_) <- brokerWith Normal (\_ _ _ _ -> fail "Invalid scopes used host") program (input (set "auth" (device "User.ReadBasic.All") configuration))
    assert "basic scope insufficient" . (== ("Left" :: Text.Text)) =<< maybe (fail "No result") (get "tag") invalid
  [ghcResult,mhsResult] <- readIORef outputs
  assert "GHC/MicroHs parity" (ghcResult == mhsResult)
  reader <- right (capturedReadSources TextType payload payload "MicrosoftGraph.Directory.Read.directory" sources)
  (readers,_) <- compileBoth temporary toolchain compiler "graph-directory-read" reader
  first:_ <- pure ghcResult
  stored <- get "value" first >>= get "evidence"
  forM_ readers $ \program -> forM_ [(tagged "Some" stored,"Right"),(none,"Left"),(tagged "Some" (set "payload" (object ["tag" .= text "Truncated"]) stored),"Left")] $ \(found,expected) -> do
    let respond _ "evidence" "read" _ = pure (tagged "Right" found,Bytes.empty)
        respond _ _ _ _ = fail "Captured directory read used network"
    (result,_,_) <- brokerWith Normal respond program (object ["arguments" .= text "directory","snapshot" .= text "prior"])
    assert "captured read" . (== (expected :: Text.Text)) =<< maybe (fail "No result") (get "tag") result
  putStrLn "Directory snapshots: ordering, changes, auth, failures, reads and compiler parity passed."

configuration :: Value
configuration = object ["auth" .= tagged "ClientSecret" (object ["tenant" .= text "tenant","clientId" .= text "client","secretKey" .= text "secret"])]
device :: Text.Text -> Value
device permission = tagged "DeviceCode" (object ["tenant" .= text "tenant","clientId" .= text "client","tokenKey" .= text "secret","scopes" .= [permission]])
input :: Value -> Value
input config = object ["concurrency" .= text "4","arguments" .= config,"snapshot" .= text "prior"]

provider :: Maybe Value -> Text.Text -> IO (Bytes.ByteString -> String -> String -> Value -> IO (Value,Bytes.ByteString), IORef [Text.Text])
provider old scenario = do
  trace <- newIORef []
  let respond _ capability method args = case (capability,method) of
        ("secrets","get") -> pure (tagged "Right" (text "secret-value"),Bytes.empty)
        ("digest","text") -> do values <- right (parseEither parseJSON args); pure (toJSON (runPureEff (runContentDigest (Digest.digestText values))),Bytes.empty)
        ("evidence","read") -> do
          assert "stable snapshot ID" . (== ("directory" :: Text.Text)) =<< get "id" args
          pure (tagged "Right" (maybe none (tagged "Some") old),Bytes.empty)
        ("http","send") -> do
          url <- get "url" args
          if "login.microsoftonline.com" `Text.isInfixOf` url then pure (http 200 "{\"access_token\":\"token\"}")
          else do
            assert "credentials left Graph" ("https://graph.microsoft.com/v1.0/users?" `Text.isPrefixOf` url)
            headers <- get "headers" args :: IO [Value]
            assert "authenticated directory request" (object ["name" .= text "Authorization","value" .= text "Bearer token"] `elem` headers)
            assert "no capture filter" (not ("$filter" `Text.isInfixOf` url))
            modifyIORef' trace (url:)
            let second = "page=2" `Text.isSuffixOf` url
                key = if second /= (scenario == "reordered") then "a" else "b"
                row = userValue scenario (if scenario == "duplicate" then "b" else key) <>
                  (if scenario == "added" && second then "," <> userValue scenario "c" else "")
                next = if scenario == "foreign" then "https://example.invalid/leak" else if scenario == "cycle" then url else "https://graph.microsoft.com/v1.0/users?page=2"
            pure $ if scenario == "denied" || scenario == "late-denied" && second then http 403 "{}"
              else if scenario == "late-failure" && second then http 500 "{}"
              else if scenario == "malformed" then http 200 "{}"
              else if scenario == "empty" || scenario == "removed" && second then http 200 "{\"value\":[]}"
              else http 200 ("{\"value\":[" <> row <> "]" <> (if second then "" else ",\"@odata.nextLink\":\"" <> next <> "\"") <> "}")
        _ -> fail ("Unexpected capability " ++ capability ++ "/" ++ method)
  pure (respond,trace)

userValue :: Text.Text -> Text.Text -> Text.Text
userValue scenario key = "{\"id\":\"" <> (if scenario == "empty-id" then "" else key) <> "\",\"displayName\":\"" <>
  (if scenario == "changed" then "Changed" else "Name 雪") <> "\",\"givenName\":null,\"surname\":null," <>
  (if scenario == "missing" then "" else "\"mail\":null,") <>
  "\"userPrincipalName\":\"user@example.test\",\"accountEnabled\":" <>
  (if scenario == "null-enabled" then "null" else if scenario == "bad-type" then "\"false\"" else if key == "a" then "false" else "true") <>
  ",\"userType\":\"" <> (if key == "a" then "Guest" else "Member") <> "\"}"

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
