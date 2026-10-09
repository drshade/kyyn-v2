-- Real GHC/MicroHs GitHub adapters against synthetic HTTP/secrets/evidence.
-- Covers bulk discussion joins/pagination, optional auth/branch/date, always-open
-- scope, discussion edits/removals, immutable commit reuse, and atomic refusal.
-- No live GitHub requests or credentials; installed catalogue covered separately.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (Value(..), FromJSON, object, (.=), (.:), encode, toJSON)
import Data.Aeson.Key (Key)
import Data.Aeson.Types (parseEither, withObject, parseJSON)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Data.IORef (IORef, newIORef, modifyIORef', readIORef)
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
import PluginFetchTests (compileBoth, brokerWith, Scenario(..))
import System.Directory (findExecutable)
import System.Environment (getEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeExtension)
import System.Info (compilerVersion)
import System.IO.Temp (withSystemTempDirectory)

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
get :: FromJSON a => Key -> Value -> IO a
get key = right . parseEither (withObject "fixture" (.: key))
text :: Text.Text -> Value
text = String
tag :: Text.Text -> Value -> Value
tag name value = object ["tag" .= name,"value" .= value]
none :: Value
none = object ["tag" .= text "None"]
base :: Text.Text
base = "https://api.github.com/repos/acme/project/"
account :: Value
account = object ["login" .= text "author","html_url" .= text "https://github.com/author"]

main :: IO ()
main = withSystemTempDirectory "kyyn-github-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  toolchain <- getEnv "KYYN_TEST_TOOLCHAIN"
  compiler <- findExecutable ("ghc-" ++ showVersion compilerVersion) >>= maybe (fail "Matching GHC required") pure
  scope <- right (directoryScope temporary)
  let directories = map (repo </>) ["shared/kyyn-types/src","guest/kyyn-sdk/src","guest/kyyn-runtime/src","vendor/json","vendor/transformers","plugins/github/src"]
  trees <- mapM (\folder -> do
    selected <- right (directoryScope folder)
    runEff (runFailure (runFileSystemIO scope (readTree selected))) >>= right) directories
  let sources = filter ((== ".hs") . takeExtension . relativeName . fst) (concatMap files trees)
      inspect name = fmap fst <$> inspectDataType toolchain directories name >>= right
  config <- inspect "GitHub.Types.RepositoryConfig"
  payload <- inspect "GitHub.Types.RepositoryItem"
  adapter <- right (acquisitionSources config payload Nothing "GitHub.Repository.fetch" sources)
  (programs,_) <- compileBoth temporary toolchain compiler "github" adapter
  results <- newIORef []
  forM_ programs $ \program -> do
    let invoke prior changed problem authenticated = do
          (respond,trace) <- provider prior changed problem authenticated
          (result,_,status) <- brokerWith Normal respond program (input authenticated)
          assert "GitHub guest failed" (status == ExitSuccess)
          value <- maybe (fail "No GitHub result") pure result
          calls <- readIORef trace
          pure (value,calls)
    (first,trace) <- invoke Map.empty False "" False
    changes <- get "value" first :: IO [Value]
    assert "wrong first capture size" (length changes == 4)
    prior <- Map.fromList <$> mapM (\change -> do entry <- get "value" change; (,) <$> get "id" entry <*> get "evidence" entry) changes
    assert "PR appeared as duplicate issue" (Map.member "acme/project/pulls/2" prior && not (Map.member "acme/project/issues/2" prior))
    assert "patch text persisted" (not ("PATCH_MUST_NOT_SURVIVE" `Bytes.isInfixOf` Lazy.toStrict (encode changes)))
    capturedCommit <- maybe (fail "Missing commit") pure (Map.lookup "acme/project/commits/abc" prior)
      >>= get "payload" >>= get "value" >>= get "value"
    fileList <- get "files" capturedCommit :: IO [Value]
    assert "commit files weren't paginated" (length fileList == 2)
    assert "rename origin missing" . (== tag "Some" (text "old.txt")) =<< get "previousPath" (fileList !! 1)
    assert "small file list marked incomplete" =<< get "filesComplete" capturedCommit
    assert "branch override or initial date missing" (any (Text.isInfixOf "sha=develop") trace && any (Text.isInfixOf "since=2026-01") trace)
    assert "old open items excluded by since" ((base <> "issues?state=open&sort=updated&direction=asc&per_page=100") `elem` trace)
    assert "per-item comments or PR details fetched" (not (any (\url ->
      "/issues/1/comments" `Text.isInfixOf` url || "/issues/2/comments" `Text.isInfixOf` url ||
      "/pulls/2" `Text.isSuffixOf` url) trace))
    assert "bulk pagination not followed" (any (Text.isInfixOf "issues/comments?page=2") trace &&
      any (Text.isInfixOf "pulls?page=2") trace)
    pull <- maybe (fail "Missing PR") pure (Map.lookup "acme/project/pulls/2" prior)
      >>= get "payload" >>= get "value" >>= get "value"
    assert "merged flag not derived from listing timestamp" =<< get "merged" pull
    (second,secondTrace) <- invoke prior False "" True
    assert "unchanged fetch emitted changes" . null =<< (get "value" second :: IO [Value])
    assert "known commit details refetched" (not (any (Text.isInfixOf "/commits/") secondTrace))
    (third,_) <- invoke prior True "" False
    updated <- get "value" third :: IO [Value]
    assert "comment/review-only changes missed" (length updated == 2)
    forM_ updated $ \change -> assert "discussion update classified as new" . (== ("Updated" :: Text.Text)) =<< get "tag" change
    (removed,_) <- invoke prior False "removed-comment" False
    removedChanges <- get "value" removed :: IO [Value]
    assert "removed comment not reflected" (length removedChanges == 1)
    forM_ ["rate","cycle","foreign","missing-pr","duplicate-pr","comment-page-failure"] $ \problem -> do
      (failed,_) <- invoke Map.empty False problem False
      assert "failed acquisition exposed partial batch" . (== ("Left" :: Text.Text)) =<< get "tag" failed
      if problem == "rate" then assert "retry details lost" . Text.isInfixOf "Retry-After: 60" =<< (get "value" failed :: IO Text.Text) else pure ()
    (empty,_) <- invoke Map.empty False "empty" False
    assert "empty repository refused" . null =<< (get "value" empty :: IO [Value])
    (atCeiling,_) <- invoke Map.empty False "ceiling" False
    assert "API file ceiling reported complete" ("\"filesComplete\":false" `Bytes.isInfixOf` Lazy.toStrict (encode atCeiling))
    (defaultRespond,defaultTrace) <- provider Map.empty False "" False
    (defaultResult,_,_) <- brokerWith Normal defaultRespond program defaultInput
    _ <- maybe (fail "No default-config result") (get "value" :: Value -> IO [Value]) defaultResult
    defaultCalls <- readIORef defaultTrace
    assert "default scope added branch/date restriction" (not (any (\url -> "since=" `Text.isInfixOf` url || "sha=" `Text.isInfixOf` url) defaultCalls))
    assert "default scope did not request full history" (any (Text.isInfixOf "state=all") defaultCalls)
    modifyIORef' results (first:)
  parity <- readIORef results
  case parity of [a,b] -> assert "GHC/MicroHs captures differ" (a == b); _ -> fail "Missing compiler result"
  reader <- right (capturedReadSources TextType payload payload "GitHub.Read.item" sources)
  (readers,_) <- compileBoth temporary toolchain compiler "github-read" reader
  first <- case parity of value:_ -> pure value; _ -> fail "Missing fixture"
  changes <- get "value" first :: IO [Value]
  example <- get "value" (changes !! 0) >>= get "evidence"
  forM_ readers $ \program -> do
    (respond,_) <- provider (Map.singleton "selected" example) False "" False
    (result,_,status) <- brokerWith Normal respond program (object ["arguments" .= text "selected","snapshot" .= text "selected"])
    assert "captured reader failed" (status == ExitSuccess)
    output <- maybe (fail "No read result") pure result
    expected <- get "payload" example >>= get "value"
    assert "typed reader changed payload" (output == tag "Right" expected)
  putStrLn "GitHub: GHC/MicroHs fetch/read parity, pagination, mutable discussions, commit reuse and refusals passed."

input :: Bool -> Value
input authenticated = object ["arguments" .= object
  ["repositoryUrl" .= text "https://github.com/acme/project.git/"
  ,"branch" .= tag "Some" (text "develop"),"since" .= tag "Some" (text "2026-01-01T00:00:00Z")
  ,"tokenSecret" .= (if authenticated then tag "Some" (text "github-token") else none)]
  ,"snapshot" .= text "selected"]

defaultInput :: Value
defaultInput = object ["arguments" .= object
  ["repositoryUrl" .= text "https://github.com/acme/project", "branch" .= none, "since" .= none, "tokenSecret" .= none],"snapshot" .= text "selected"]

provider :: Map.Map Text.Text Value -> Bool -> Text.Text -> Bool
  -> IO (Bytes.ByteString -> String -> String -> Value -> IO (Value,Bytes.ByteString), IORef [Text.Text])
provider prior changed problem authenticated = do
  trace <- newIORef []
  let respond _ capability method args = case (capability,method) of
        ("secrets","get") -> assert "public fetch read secret" authenticated >> pure (tag "Right" (text "fixture-token"),Bytes.empty)
        ("digest","text") -> do
          values <- right (parseEither parseJSON args)
          pure (toJSON (runPureEff (runContentDigest (Digest.digestText values))),Bytes.empty)
        ("evidence","list") -> pure (tag "Right" (toJSON (Map.keys prior)),Bytes.empty)
        ("evidence","read") -> do
          key <- get "id" args
          pure (tag "Right" (maybe none (tag "Some") (Map.lookup key prior)),Bytes.empty)
        ("http","send") -> do
          url <- get "url" args
          headers <- get "headers" args :: IO [Value]
          pairs <- mapM (\v -> (,) <$> get "name" v <*> get "value" v) headers :: IO [(Text.Text,Text.Text)]
          assert "wrong auth headers" (lookup "Authorization" pairs == if authenticated then Just "Bearer fixture-token" else Nothing)
          modifyIORef' trace (url:)
          let response status links body = pure (tag "Right" (object ["status" .= text status,"headers" .=
                [object ["name" .= text "Link","value" .= text links] | not (Text.null links)]]), Lazy.toStrict (encode body))
              ok = response "200" ""
              next path = "<" <> base <> path <> ">; rel=\"next\""
          if problem == "rate" && "issues/comments" `Text.isInfixOf` url then pure
            (tag "Right" (object ["status" .= text "403","headers" .= [object ["name" .= text "Retry-After","value" .= text "60"]]]), "{}")
          else if problem == "empty" && "/issues?" `Text.isInfixOf` url then ok (toJSON ([] :: [Value]))
          else if problem == "empty" && "/commits?" `Text.isInfixOf` url then response "409" "" (object ["message" .= text "Git Repository is empty."])
          else if "/issues?state=open" `Text.isInfixOf` url || "/issues?state=all" `Text.isInfixOf` url then
            response "200" (case problem of "cycle" -> "<" <> url <> ">; rel=\"next\""; "foreign" -> "<https://example.invalid/steal>; rel=\"next\""; _ -> "") (toJSON [issue 1 False,issue 2 True])
          else if "/issues?state=closed" `Text.isInfixOf` url then ok (toJSON ([] :: [Value]))
          else if "/issues/comments" `Text.isInfixOf` url then
            if "page=2" `Text.isSuffixOf` url then
              if problem == "comment-page-failure" then response "500" "" (object [])
              else ok (toJSON ([comment 2 changed | problem /= "removed-comment"] ++ [comment 999 False]))
            else response "200" (next "issues/comments?page=2") (toJSON [comment 1 changed])
          else if "/reviews" `Text.isInfixOf` url then ok (toJSON [review changed])
          else if "/pulls?" `Text.isInfixOf` url then
            if "page=2" `Text.isSuffixOf` url then ok (toJSON
              (case problem of "missing-pr" -> []; "duplicate-pr" -> [pullDetails,pullDetails]; _ -> [pullDetails]))
            else response "200" (next "pulls?page=2") (toJSON ([] :: [Value]))
          else if "/commits?" `Text.isInfixOf` url then
            if "page=2" `Text.isSuffixOf` url then ok (toJSON [object ["sha" .= text "def"]])
            else response "200" "<https://api.github.com/repositories/123/commits?page=2>; rel=\"next\"" (toJSON [object ["sha" .= text "abc"]])
          else if "/commits/abc?" `Text.isInfixOf` url then
            if "page=2" `Text.isSuffixOf` url then ok (commit "abc" [renamed])
            else response "200" (next "commits/abc?page=2") (commit "abc" [added])
          else if "/commits/def?" `Text.isInfixOf` url then ok (commit "def"
            (if problem == "ceiling" then [object ["filename" .= ("file-" <> Text.pack (show n)),"status" .= text "modified"] | n <- [1..3000 :: Int]] else []))
          else fail ("Unexpected GitHub URL: " ++ Text.unpack url)
        _ -> fail ("Unexpected capability: " ++ capability ++ "/" ++ method)
  pure (respond,trace)

issue :: Integer -> Bool -> Value
issue number pull = object $
  ["number" .= number,"title" .= text "Plan 雪","body" .= Null,"state" .= text "open","user" .= Null
  ,"url" .= (base <> "issues/" <> Text.pack (show number))
  ,"assignees" .= [account],"labels" .= [object ["name" .= text "feature"]],"milestone" .= Null
  ,"created_at" .= text "2020-01-01T00:00:00Z","updated_at" .= text "2020-01-01T00:00:00Z","closed_at" .= Null
  ,"html_url" .= ("https://github.com/acme/project/" <> (if pull then "pull/" else "issues/") <> Text.pack (show number))]
  ++ ["pull_request" .= object [] | pull]
comment :: Integer -> Bool -> Value
comment number changed = object ["id" .= (number + 10),"issue_url" .= (base <> "issues/" <> Text.pack (show number))
  ,"user" .= account,"body" .= text (if changed then "Edited discussion" else "Discussion 雪")
  ,"created_at" .= text "2020-01-01T00:00:00Z","updated_at" .= text "2020-01-01T00:00:00Z","html_url" .= text "https://github.com/comment"]
review :: Bool -> Value
review changed = object ["id" .= (34 :: Integer),"user" .= Null,"body" .= text (if changed then "Edited review" else "LGTM")
  ,"state" .= text "APPROVED","submitted_at" .= text "2020-01-01T00:00:00Z","commit_id" .= text "head","html_url" .= text "https://github.com/review"]
pullDetails :: Value
pullDetails = object
  ["number" .= (2 :: Integer),"draft" .= False,"merged_at" .= text "2026-02-01T00:00:00Z","merge_commit_sha" .= text "merge"
  ,"base" .= object ["ref" .= text "main","sha" .= text "base"],"head" .= object ["ref" .= text "feature","sha" .= text "head"]]
commit :: Text.Text -> [Value] -> Value
commit sha changedFiles = object ["sha" .= sha,"html_url" .= ("https://github.com/acme/project/commit/" <> sha)
  ,"commit" .= object ["message" .= text "Implement feature\n\nBecause reasons.","author" .= Null,"committer" .= object
     ["name" .= text "Git author","email" .= text "author@example.test","date" .= text "2026-02-01T00:00:00Z"]]
  ,"parents" .= [object ["sha" .= text "parent"]],"files" .= changedFiles]
added, renamed :: Value
added = object ["filename" .= text "new.txt","status" .= text "added","patch" .= text "PATCH_MUST_NOT_SURVIVE"]
renamed = object ["filename" .= text "renamed.txt","status" .= text "renamed","previous_filename" .= text "old.txt"]
