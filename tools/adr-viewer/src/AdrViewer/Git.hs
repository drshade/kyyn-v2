-- | The only process boundary: git for history and blobs, gh for merged PRs.
{-# LANGUAGE OverloadedStrings #-}
module AdrViewer.Git (Commit(..), PullRequest(..), firstParentLog, changedFiles, listTree, readBlobs, mergedPullRequests, repoIdentity) where

import Control.Monad (forM)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import System.Process.Typed

data Commit = Commit { commitSha :: Text, commitParent :: Maybe Text, commitDate :: Text, commitSubject :: Text }

data PullRequest = PullRequest
  { prNumber :: Int, prTitle :: Text, prBody :: Text, prMergeSha :: Text }

decodeUtf8 :: BS.ByteString -> Text
decodeUtf8 = TE.decodeUtf8With TE.lenientDecode

textOf :: BS.ByteString -> Text
textOf bytes
  | BS.elem 0 (BS.take 8000 bytes) = T.empty
  | otherwise = decodeUtf8 bytes

git :: FilePath -> [String] -> IO Text
git repo args = decodeUtf8 . BL.toStrict <$> readProcessStdout_ (proc "git" ("-C" : repo : args))

firstParentLog :: FilePath -> String -> IO [Commit]
firstParentLog repo branch = do
  out <- git repo ["log", "--first-parent", "--reverse", "--format=%H%x09%P%x09%cI%x09%s", branch]
  pure [ Commit sha (case T.words parents of p : _ -> Just p; [] -> Nothing) date subject
       | line <- T.lines out, (sha : parents : date : rest) <- [T.splitOn "\t" line]
       , let subject = T.intercalate "\t" rest ]

-- | Paths changed against the first parent; every path for a root commit.
changedFiles :: FilePath -> Commit -> IO [Text]
changedFiles repo c = T.lines <$> case commitParent c of
  Just p -> git repo ["diff", "--name-only", T.unpack p, T.unpack (commitSha c)]
  Nothing -> git repo ["ls-tree", "-r", "--name-only", T.unpack (commitSha c)]

-- | Every path under a prefix in the tree at a commit.
listTree :: FilePath -> Text -> Text -> IO [Text]
listTree repo sha prefix = T.lines <$> git repo ["ls-tree", "-r", "--name-only", T.unpack sha, T.unpack prefix]

-- | Read many paths at one commit through a single @git cat-file --batch@.
-- Paths missing at that commit are absent from the result. Binary blobs (a NUL in
-- the first 8000 bytes, git's own test) read as empty text: they name no anchors,
-- and lenient decoding of large binaries is very slow.
readBlobs :: FilePath -> Text -> [Text] -> IO (Map Text Text)
readBlobs _ _ [] = pure Map.empty
readBlobs repo sha paths = do
  let input = BL.fromStrict (TE.encodeUtf8 (T.concat [sha <> ":" <> p <> "\n" | p <- paths]))
  out <- BL.toStrict <$> readProcessStdout_ (setStdin (byteStringInput input) (proc "git" ["-C", repo, "cat-file", "--batch"]))
  pure (Map.fromList (catMaybes (parse paths out)))
  where
    parse [] _ = []
    parse (p : ps) bytes =
      let (header, rest) = BC.break (== '\n') bytes
          body = BS.drop 1 rest
      in case BC.words header of
           [_, _, size] | Just (n, _) <- BC.readInt size ->
             Just (p, textOf (BS.take n body)) : parse ps (BS.drop (n + 1) body)
           _ -> Nothing : parse ps body

mergedPullRequests :: FilePath -> IO [PullRequest]
mergedPullRequests repo = do
  out <- readProcessStdout_ (setWorkingDir repo (proc "gh"
    ["pr", "list", "--state", "merged", "--limit", "5000", "--json", "number,title,body,mergeCommit"]))
  rows <- either fail pure (eitherDecode out)
  fmap catMaybes . forM rows $ \v -> pure (parseMaybe row v)
  where
    row = withObject "pr" $ \o -> do
      merge <- o .:? "mergeCommit"
      sha <- maybe (fail "unmerged") (.: "oid") merge
      PullRequest <$> o .: "number" <*> o .: "title" <*> (maybe "" id <$> o .:? "body") <*> pure sha

-- | @owner/name@ and its web URL, when gh knows the repository.
repoIdentity :: FilePath -> IO (Maybe (Text, Text))
repoIdentity repo = do
  (code, out, _) <- readProcess (setWorkingDir repo (proc "gh" ["repo", "view", "--json", "nameWithOwner,url"]))
  pure $ case code of
    ExitSuccess -> parseMaybe (withObject "repo" (\o -> (,) <$> o .: "nameWithOwner" <*> o .: "url")) =<< decode out
    _ -> Nothing
