-- | Mechanical evidence: walk first-parent history and record, per step, which
-- ADRs changed and how anchors moved between the spec and the code.
--
-- Writes the committed index (@steps.json@, @adrs.json@, @repo.json@) and the
-- ignored worklists the curating agent reads (@worklists/<ADR>.jsonl@,
-- @worklists/anchors.json@, @worklists/steps.jsonl@). Running it twice on the
-- same history produces identical committed files.
{-# LANGUAGE OverloadedStrings #-}
module AdrViewer.Extract (ExtractOptions(..), extract, unifiedDiff) where

import AdrViewer.Adr
import AdrViewer.Git
import AdrViewer.Json
import AdrViewer.Types
import Control.Monad (foldM, forM_)
import Data.Aeson (Value, object, (.=))
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Algorithm.Diff (PolyDiff(..), getDiff)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

data ExtractOptions = ExtractOptions { optRepo :: FilePath, optBranch :: String, optOutput :: FilePath }

-- | What one step did, before it is split into the index and the worklists.
data StepFacts = StepFacts
  { sfStep :: Step, sfBody :: Text, sfCodeFiles :: [Text]
  , sfChanges :: [(Text, Value, Text)]          -- ^ (ADR, change summary, unified diff)
  , sfSpecAdded :: [(Text, Text)], sfSpecRemoved :: [(Text, Text)]  -- ^ (anchor, ADR)
  , sfCodeAdded :: [Text], sfCodeRemoved :: [Text] }

data Walk = Walk
  { wText :: Map Text Text, wSpec :: Map Text (Set Text), wCodeFiles :: Map Text (Set Text)
  , wCode :: Set Text, wAdrs :: Map Text Adr, wFacts :: [StepFacts] }

extract :: ExtractOptions -> IO ()
extract opts = do
  let repo = optRepo opts
  commits <- firstParentLog repo (optBranch opts)
  prs <- Map.fromList . map (\p -> (prMergeSha p, p)) <$> mergedPullRequests repo
  identity <- repoIdentity repo
  -- Pass 1: ADR text at every step, and the universe of anchors ever named.
  texts <- mapM (adrTexts repo) commits
  let universe = Set.unions [anchorsIn t | m <- texts, t <- Map.elems m]
  -- Pass 2: walk the steps, diffing ADRs and tracking anchors in code incrementally.
  final <- foldM (walkStep repo universe prs) (Walk Map.empty Map.empty Map.empty Set.empty Map.empty [])
             (zip3 [0 ..] commits texts)
  let facts = reverse (wFacts final)
      out = optOutput opts
      work = out </> "worklists"
  createDirectoryIfMissing True work
  writeJson (out </> "steps.json") (map sfStep facts)
  writeJson (out </> "adrs.json") (Map.elems (wAdrs final))
  writeJson (out </> "repo.json") (Repo (maybe "repository" fst identity) (snd <$> identity))
  writeJson (work </> "anchors.json") (anchorEvents facts)
  BLC.writeFile (work </> "steps.jsonl") (BLC.unlines (map (encodeCompact . fullStep) facts))
  forM_ (Map.keys (wAdrs final)) $ \adr ->
    BLC.writeFile (work </> T.unpack adr <> ".jsonl")
      (BLC.unlines [encodeCompact (laneEntry adr f c d) | f <- facts, (a, c, d) <- sfChanges f, a == adr])
  putStrLn (show (length facts) <> " steps, " <> show (Map.size (wAdrs final)) <> " ADRs, "
            <> show (Set.size universe) <> " anchors -> " <> out)

adrTexts :: FilePath -> Commit -> IO (Map Text Text)
adrTexts repo c = do
  names <- filter (isJust . adrFileId) <$> listTree repo (commitSha c) "architecture/adr/"
  blobs <- readBlobs repo (commitSha c) names
  pure (Map.fromList [(i, t) | (p, t) <- Map.toList blobs, Just i <- [adrFileId p]])

walkStep :: FilePath -> Set Text -> Map Text PullRequest -> Walk -> (Int, Commit, Map Text Text) -> IO Walk
walkStep repo universe prs w (seqNo, c, cur) = do
  changed <- changedFiles repo c
  let codePaths = filter isCodePath changed
  blobs <- readBlobs repo (commitSha c) codePaths
  let codeFiles = foldl' (\m p -> case Map.lookup p blobs of
                                    Just t -> Map.insert p (identifiers t `Set.intersection` universe) m
                                    Nothing -> Map.delete p m) (wCodeFiles w) codePaths
      code = Set.unions (Map.elems codeFiles)
      spec = Map.fromListWith Set.union [(a, Set.singleton adr) | (adr, t) <- Map.toList cur, a <- Set.toList (anchorsIn t)]
      ids = Set.toList (Map.keysSet (wText w) <> Map.keysSet cur)
      changes = [ (adr, summary before after, unifiedDiff adr before after)
                | adr <- ids, let before = Map.findWithDefault "" adr (wText w)
                , let after = Map.findWithDefault "" adr cur, before /= after ]
      pr = Map.lookup (commitSha c) prs
      adrs = foldl' (noteAdr seqNo cur) (wAdrs w) [a | (a, _, _) <- changes]
      moved f g = [ (a, adr) | a <- Set.toList (Map.keysSet spec <> Map.keysSet (wSpec w))
                  , adr <- Set.toList (f a Set.\\ g a) ]
      now a = Map.findWithDefault Set.empty a spec
      was a = Map.findWithDefault Set.empty a (wSpec w)
      step = Step seqNo (commitSha c) (commitDate c) (prNumber <$> pr)
                  (maybe (commitSubject c) prTitle pr) [a | (a, _, _) <- changes]
      facts = StepFacts step (maybe "" prBody pr) codePaths changes (moved now was) (moved was now)
                (Set.toList (code Set.\\ wCode w)) (Set.toList (wCode w Set.\\ code))
  pure w { wText = cur, wSpec = spec, wCodeFiles = codeFiles, wCode = code, wAdrs = adrs, wFacts = facts : wFacts w }

noteAdr :: Int -> Map Text Text -> Map Text Adr -> Text -> Map Text Adr
noteAdr seqNo cur m adr = Map.insert adr updated m
  where
    existing = Map.findWithDefault (Adr adr Nothing seqNo Nothing) adr m
    text = Map.lookup adr cur
    updated = existing
      { adrTitle = maybe (adrTitle existing) (\t -> maybe (adrTitle existing) Just (titleOf t)) text
      , adrDeleted = if isJust text then Nothing else Just seqNo }


summary :: Text -> Text -> Value
summary before after = object
  [ "change" .= (if T.null before then "added" else if T.null after then "removed" else "modified" :: Text)
  , "sections" .= [ object ["heading" .= h, "change" .= kind h] | h <- headings ] ]
  where
    sb = sections before
    sa = sections after
    headings = filter (\h -> Map.lookup h sb /= Map.lookup h sa) (Map.keys (Map.union sa sb))
    kind h | Map.notMember h sb = "added" :: Text
           | Map.notMember h sa = "removed"
           | otherwise = "modified"

-- | A unified diff with two lines of context, for the curating agent to read.
unifiedDiff :: Text -> Text -> Text -> Text
unifiedDiff name before after
  | null hunks = ""
  | otherwise = T.unlines (("--- a/" <> name) : ("+++ b/" <> name) : concatMap render hunks)
  where
    ops = numbered 1 1 (getDiff (T.lines before) (T.lines after))
    changedAt = [i | (i, (_, _, op, _)) <- zip [0 :: Int ..] ops, op /= ' ']
    hunks = map (\(a, b) -> take (b - a + 1) (drop a ops)) (spans changedAt)
    spans [] = []
    spans (i : is) = go (i, i) is
      where go (a, b) (j : js) | j - b <= 4 = go (a, j) js
                               | otherwise = clip (a, b) : go (j, j) js
            go r [] = [clip r]
    clip (a, b) = (max 0 (a - 2), min (length ops - 1) (b + 2))
    render h = header h : [T.singleton op <> line | (_, _, op, line) <- h]
    header h = let olds = [o | (o, _, op, _) <- h, op /= '+']
                   news = [n | (_, n, op, _) <- h, op /= '-']
                   start xs alt = case xs of x : _ -> x; [] -> alt
                   (o0, n0) = case h of (o, n, _, _) : _ -> (o, n); [] -> (0, 0)
               in T.pack ("@@ -" <> show (start olds (o0 - 1)) <> "," <> show (length olds)
                          <> " +" <> show (start news (n0 - 1)) <> "," <> show (length news) <> " @@")
    numbered :: Int -> Int -> [PolyDiff Text Text] -> [(Int, Int, Char, Text)]
    numbered o n (d : ds) = case d of
      Both l _ -> (o, n, ' ', l) : numbered (o + 1) (n + 1) ds
      First l -> (o, n, '-', l) : numbered (o + 1) n ds
      Second l -> (o, n, '+', l) : numbered o (n + 1) ds
    numbered _ _ [] = []

anchorEvents :: [StepFacts] -> Map Text [Value]
anchorEvents facts = Map.fromListWith (flip (<>)) $ concat
  [ [(a, [event f "spec_added" (Just adr)]) | (a, adr) <- sfSpecAdded f]
    <> [(a, [event f "spec_removed" (Just adr)]) | (a, adr) <- sfSpecRemoved f]
    <> [(a, [event f "code_added" Nothing]) | a <- sfCodeAdded f]
    <> [(a, [event f "code_removed" Nothing]) | a <- sfCodeRemoved f]
  | f <- facts ]
  where
    event :: StepFacts -> Text -> Maybe Text -> Value
    event f kind adr = object (["seq" .= stepSeq (sfStep f), "kind" .= kind] <> maybe [] (\d -> ["adr" .= d]) adr)

fullStep :: StepFacts -> Value
fullStep f = object
  [ "seq" .= stepSeq s, "sha" .= stepSha s, "date" .= stepDate s, "pr" .= stepPr s, "title" .= stepTitle s
  , "body" .= sfBody f, "code_files" .= sfCodeFiles f
  , "adr_changes" .= [object ["adr" .= a, "summary" .= c] | (a, c, _) <- sfChanges f]
  , "anchors" .= object [ "spec_added" .= sfSpecAdded f, "spec_removed" .= sfSpecRemoved f
                        , "code_added" .= sfCodeAdded f, "code_removed" .= sfCodeRemoved f ] ]
  where s = sfStep f

laneEntry :: Text -> StepFacts -> Value -> Text -> Value
laneEntry adr f change diff = object
  [ "seq" .= stepSeq s, "date" .= stepDate s, "pr" .= stepPr s, "title" .= stepTitle s, "body" .= sfBody f
  , "code_files" .= sfCodeFiles f, "other_adrs" .= filter (/= adr) (stepAdrs s)
  , "change" .= change, "diff" .= diff
  , "spec_added" .= [a | (a, d) <- sfSpecAdded f, d == adr]
  , "spec_removed" .= [a | (a, d) <- sfSpecRemoved f, d == adr]
  , "code_added" .= sfCodeAdded f ]
  where s = sfStep f

