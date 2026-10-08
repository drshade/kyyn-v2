-- ADR readings (anchors, sections), lane checks and the derived model: realisation,
-- liveness, track exclusivity and per-step counts, including QuickCheck properties
-- over generated lanes.

{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import AdrViewer.Adr
import AdrViewer.Check
import AdrViewer.Model
import AdrViewer.Pending
import AdrViewer.Types
import Control.Monad (unless)
import Data.Aeson (decode, encode)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Test.QuickCheck

main :: IO ()
main = do
  let assert name ok = unless ok (fail name)
      adrText = T.unlines
        [ "# Storage", "", "## Decision", "Use `MaterializeRoot` and `Text` and `FactSnapshotRef`."
        , "### Paths", "```haskell", "loadRoot", "  :: RootRef -> Eff es Root", "data CheckedValue = X", "```" ]
      anchors = anchorsIn adrText
  assert "backtick CamelCase anchor missing" (Set.member "MaterializeRoot" anchors)
  assert "stop-listed name kept" (Set.notMember "Text" anchors)
  assert "multi-line signature missing" (Set.member "loadRoot" anchors)
  assert "fenced type missing" (Set.member "CheckedValue" anchors)
  assert "section path wrong" (Map.member "Decision / Paths" (sections adrText))
  assert "title wrong" (titleOf adrText == Just "Storage")
  assert "ADR file id wrong" (adrFileId "architecture/adr/0014-evidence.md" == Just "0014")
  assert "viewer's own files counted as code" (not (isCodePath "tools/adr-viewer/curated/lanes/0001.json"))
  assert "host source not counted as code" (isCodePath "host/kyyn/src/Main.hs")
  assert "template treated as ADR" (adrFileId "architecture/adr/0000-template.md" == Nothing)

  -- A replaced node realised before replacement, then a current replacement.
  let a = node "0001.01" 1 New [] (Realised LaterStep (Just 3) "") Nothing
      b = node "0001.02" 5 Replace ["0001.01"] (Realised SameStep Nothing "") Nothing
      c = node "0001.03" 1 New [] (Realised Unrealised Nothing "") Nothing
      lane = Lane "0001" "Product" 6 [a, b, c] [Editorial 2 Nothing "wording"] ""
      steps = [Step s "" "" Nothing "" (["0001" | s `elem` [1, 2, 5]]) | s <- [0 .. 6]]
      adrs = [Adr "0001" (Just "Product") 1 Nothing]
      view = laneView 6 lane
      states t = map (stateAt t) (lvNodes view)
  assert "realisedAt for later_step" (realisedAt a == Just 3)
  assert "same_step realises at its own step" (realisedAt b == Just 5)
  assert "liveUntil from successor" (liveUntil [a, b, c] a == Just 5)
  assert "states at step 2" (states 2 == [Planned, Hidden, Planned])
  assert "states at step 5" (states 5 == [DoneEnded, Done, Planned])
  assert "successor inherits track" (nvTrack (lvNodes view !! 1) == nvTrack (lvNodes view !! 0))
  assert "counts at step 4" (lvCounts view !! 4 == (1, 1))
  assert "valid lane has errors" (null [d | d <- checkLane steps adrs "0001.json" lane, dSeverity d == Error])
  let broken = lane { laneNodes = [b { nodeSupersedes = ["0001.99"] }], laneEditorial = [] }
      errors = [d | d <- checkLane steps adrs "0001.json" broken, dSeverity d == Error]
  assert "dangling supersedes accepted" (any (T.isInfixOf "unknown node" . dMessage) errors)
  assert "uncovered step accepted" (any (T.isInfixOf "neither a node seq" . dMessage) errors)
  assert "lane JSON does not round-trip" (decode (encode lane) == Just lane)
  let warnings l = [dMessage d | d <- checkLane steps adrs "0001.json" l, dSeverity d == Warning]
      unended = lane { laneNodes = [a { nodeEnded = Nothing }, b, c] }
      future = lane { laneNodes = [a { nodeRealised = Realised LaterStep (Just 99) "" }, b, c] }
  assert "replace without ended not warned" (any (T.isInfixOf "which has no ended") (warnings unended))
  assert "realised beyond last step not warned" (any (T.isInfixOf "beyond the last step") (warnings future))
  assert "consistent lane warned" (null (warnings lane { laneNodes = [a { nodeEnded = Just (Ended 5 Replaced (Just "0001.02")) }, b, c] }))

  -- Pending: a lane at cursor 3 of 6 has one step to curate (5), two code-only
  -- steps (4, 6), and its open decision; an uncurated ADR lists its founding steps.
  let behind = lane { laneCursor = 3, laneNodes = [a, c], laneEditorial = [Editorial 2 Nothing "wording"] }
      inputs = Inputs (Repo "r" Nothing) steps (adrs <> [Adr "0002" Nothing 2 Nothing])
                 [("0001.json", behind)]
      work = pending inputs
  assert "pending lanes wrong" (map lpAdr work == ["0001", "0002"])
  case work of
    (p1 : p2 : _) -> do
      assert "steps to curate wrong" (map stepSeq (lpCurate p1) == [5])
      assert "code-only steps wrong" (map stepSeq (lpCheck p1) == [4, 6])
      assert "open decisions wrong" (map nodeId (lpOpen p1) == ["0001.03"])
      assert "uncurated ADR has a cursor" (lpCursor p2 == Nothing)
    _ -> fail "pending returned too few lanes"
  assert "current lane reported pending" (notElem "0001" (map lpAdr (pending inputs { inLanes = [("0001.json", lane)] })))

  let props = stdArgs { maxSuccess = 300, chatty = False }
      prop name p = quickCheckWithResult props p >>= \r -> case r of
        Success {} -> pure ()
        _ -> fail (name <> ": " <> output r)
  prop "two nodes share a track while both live" (forAll genLane tracksExclusive)
  prop "counts disagree with states" (forAll genLane countsMatch)
  prop "a node turns back from realised" (forAll genLane neverUnrealises)
  putStrLn "ADR readings, lane checks and model properties passed."

node :: T.Text -> Int -> Kind -> [T.Text] -> Realised -> Maybe Ended -> Node
node i s k sup r e = Node i s Nothing "" "" k sup [] [] r e High

-- | Lanes whose nodes supersede only earlier nodes, as check requires.
genLane :: Gen Lane
genLane = do
  count <- chooseInt (1, 12)
  nodes <- go count []
  pure (Lane "0009" "Generated" 20 nodes [] "")
  where
    go 0 acc = pure (reverse acc)
    go k acc = do
      s <- chooseInt (maybe 0 nodeSeq (headMaybe acc), 20)
      let earlier = [nodeId n | n <- acc, nodeSeq n <= s]
      sup <- if null earlier then pure [] else sublistOf earlier >>= \xs -> pure (take 2 xs)
      how <- elements [minBound .. maxBound]
      rs <- chooseInt (0, 25)
      let i = "0009." <> T.pack (show (length acc + 1))
          kind = if null sup then New else Refine
      go (k - 1 :: Int) (node i s kind sup (Realised how (Just rs) "") Nothing : acc)
    headMaybe (x : _) = Just x
    headMaybe [] = Nothing

tracksExclusive :: Lane -> Bool
tracksExclusive lane = and
  [ not (overlap v w) | (i, v) <- zip [0 :: Int ..] vs, (j, w) <- zip [0 ..] vs, i < j, nvTrack v == nvTrack w ]
  where
    vs = lvNodes (laneView 25 lane)
    span' v = (nodeSeq (nvNode v), maybe 1000 id (nvUntil v))
    overlap v w = let (a, b) = span' v; (c, d) = span' w in a < d && c < b && a < b && c < d

countsMatch :: Lane -> Bool
countsMatch lane = and [ lvCounts view !! t == (count Done t, count Planned t) | t <- [0 .. 25] ]
  where
    view = laneView 25 lane
    count st t = length [v | v <- lvNodes view, stateAt t v == st]

neverUnrealises :: Lane -> Bool
neverUnrealises lane = and [ not (built (stateAt t v) && not (built (stateAt (t + 1) v))) | v <- lvNodes (laneView 25 lane), t <- [0 .. 24] ]
  where built st = st `elem` [Done, DoneEnded]
