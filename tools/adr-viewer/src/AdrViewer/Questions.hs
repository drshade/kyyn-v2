-- | Specification-gap snapshots: the score derived from one, the status of every
-- ADR's snapshot against the evidence, and the decision list a judge maps
-- questions onto. Snapshots are taken on demand, not on every change.
{-# LANGUAGE OverloadedStrings #-}
module AdrViewer.Questions
  ( Tally(..), recurring, tally, contradictions, liveAt, lastChange
  , renderStatus, renderDecisions, snapshotJson
  ) where

import AdrViewer.Check (Inputs(..))
import AdrViewer.Model (liveUntil)
import AdrViewer.Types
import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import qualified Data.Text as T

-- | Recurring questions by importance.
data Tally = Tally { tHigh, tMedium, tLow :: Int } deriving (Eq, Show)

-- | Raised by at least 60% of the independent runs (2 of 3, 3 of 5). Questions fewer
-- runs raised are mostly one agent's quirks and stay out of the score.
recurring :: Snapshot -> Question -> Bool
recurring s q = questionAsked q * 5 >= snapshotRuns s * 3

tally :: Snapshot -> Tally
tally s = Tally (count HighImpact) (count MediumImpact) (count LowImpact)
  where count i = length [ q | q <- snapshotQuestions s, recurring s q, not (isContradiction q)
                             , questionImportance q == i ]

-- | Recurring contradictions between ADRs, counted apart from gaps.
contradictions :: Snapshot -> Int
contradictions s = length [q | q <- snapshotQuestions s, recurring s q, isContradiction q]

-- | The lane's decisions live at a step.
liveAt :: Int -> Lane -> [Node]
liveAt t lane = [n | n <- laneNodes lane, nodeSeq n <= t, maybe True (> t) (liveUntil (laneNodes lane) n)]

-- | The last step that changed an ADR.
lastChange :: [Step] -> Text -> Maybe Int
lastChange steps adr = case [stepSeq s | s <- steps, adr `elem` stepAdrs s] of
  [] -> Nothing
  ss -> Just (maximum ss)

-- | One line per ADR: its snapshot's score and whether the ADR changed since.
renderStatus :: Inputs -> Text
renderStatus i = T.unlines $
  ("Evidence runs through step " <> tshow lastSeq <> maybe "" (\s -> " (" <> T.take 12 (stepSha s) <> ")") lastStep <> ".")
  : [line a | a <- inAdrs i, adrDeleted a == Nothing]
  where
    lastStep = if null (inSteps i) then Nothing else Just (last (inSteps i))
    lastSeq = maybe 0 stepSeq lastStep
    line a = adrId a <> " " <> maybe "" id (adrTitle a) <> "\n  " <> case lookup (adrId a) snaps of
      Nothing -> "no snapshot"
      Just s -> let Tally h m l = tally s in
        "step " <> tshow (snapshotStep s) <> " (" <> snapshotDate s <> "): "
          <> tshow h <> " high · " <> tshow m <> " medium · " <> tshow l <> " low recurring, of "
          <> tshow (length (snapshotQuestions s)) <> " questions"
          <> (case contradictions s of 0 -> ""; c -> "; " <> tshow c <> " recurring contradictions") <> stale s
    stale s = case lastChange (inSteps i) (snapshotAdr s) of
      Just c | c > snapshotStep s -> "; the ADR changed since, at step " <> tshow c
      _ -> ""
    snaps = [(snapshotAdr s, s) | (_, s) <- inSnapshots i]

-- | The live decisions a judge maps questions onto: ids, summaries and
-- sections only, so the judge sees nothing of the code.
renderDecisions :: Inputs -> Text -> Either Text Text
renderDecisions i adr = case [l | (_, l) <- inLanes i, laneAdr l == adr] of
  [] -> Left ("no lane for ADR " <> adr)
  lane : _ -> Right $ T.unlines
    [ nodeId n <> "  " <> nodeSummary n <> sections n | n <- liveAt (laneCursor lane) lane ]
  where sections n = if null (nodeSections n) then "" else "  [" <> T.intercalate "; " (nodeSections n) <> "]"

-- | What the page shows for a snapshot.
snapshotJson :: Inputs -> Snapshot -> Value
snapshotJson i s = object
  [ "step" .= snapshotStep s, "date" .= snapshotDate s, "runs" .= snapshotRuns s
  , "summary" .= snapshotSummary s, "lastChange" .= lastChange (inSteps i) (snapshotAdr s)
  , "tally" .= [h, m, l], "contradictions" .= contradictions s, "decisions" .= decisions
  , "questions" .= [ object
      [ "kind" .= (if isContradiction q then "contradiction" else "gap" :: Text)
      , "text" .= questionText q, "asked" .= questionAsked q, "recurring" .= recurring s q
      , "verdict" .= questionVerdict q, "importance" .= questionImportance q
      , "reason" .= questionReason q, "nodes" .= questionNodeIds q ]
    | q <- snapshotQuestions s ] ]
  where
    Tally h m l = tally s
    decisions = case [l' | (_, l') <- inLanes i, laneAdr l' == snapshotAdr s] of
      lane : _ -> Just (length (liveAt (snapshotStep s) lane))
      [] -> Nothing

tshow :: Show a => a -> Text
tshow = T.pack . show
