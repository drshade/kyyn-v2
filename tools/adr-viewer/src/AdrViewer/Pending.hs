-- | The curator's work list: for each lane behind the evidence, the steps after
-- its cursor, split into those that changed the ADR (curate them) and code-only
-- steps (check whether they realise an open decision), plus the open decisions
-- such a step could realise.
{-# LANGUAGE OverloadedStrings #-}
module AdrViewer.Pending (LanePending(..), pending, renderPending, pendingJson) where

import AdrViewer.Check (Inputs(..))
import AdrViewer.Model (liveUntil)
import AdrViewer.Types
import Data.Aeson (Value, object, (.=))
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T

data LanePending = LanePending
  { lpAdr :: Text
  , lpTitle :: Maybe Text
  , lpCursor :: Maybe Int   -- ^ Nothing when the ADR has no lane file yet
  , lpCurate :: [Step]      -- ^ steps after the cursor that changed this ADR
  , lpCheck :: [Step]       -- ^ steps after the cursor that did not
  , lpOpen :: [Node] }      -- ^ live decisions still unrealised or unknown
  deriving (Eq, Show)

-- | Every ADR whose lane is missing or behind the last step, in ADR order.
pending :: Inputs -> [LanePending]
pending i = [p | adr <- inAdrs i, Just p <- [forAdr adr]]
  where
    lanes = [(laneAdr l, l) | (_, l) <- inLanes i]
    lastSeq = if null (inSteps i) then 0 else maximum (map stepSeq (inSteps i))
    forAdr adr = case lookup (adrId adr) lanes of
      Nothing -> Just (LanePending (adrId adr) (adrTitle adr) Nothing
        [s | s <- inSteps i, adrId adr `elem` stepAdrs s] [] [])
      Just lane
        | laneCursor lane >= lastSeq -> Nothing
        | otherwise ->
            let after = [s | s <- inSteps i, stepSeq s > laneCursor lane]
                touches s = laneAdr lane `elem` stepAdrs s
            in Just (LanePending (laneAdr lane) (adrTitle adr) (Just (laneCursor lane))
                  (filter touches after) (filter (not . touches) after) (openNodes lane))

-- | Live at the cursor (not ended or superseded) and not known to be realised.
openNodes :: Lane -> [Node]
openNodes lane =
  [ n | n <- laneNodes lane, isNothing (liveUntil (laneNodes lane) n)
  , realisedHow (nodeRealised n) `elem` [Unrealised, Unknown] ]

renderPending :: Int -> [LanePending] -> Text
renderPending lastSeq ps
  | null ps = "All lanes are current through step " <> tshow lastSeq <> ".\n"
  | otherwise = T.unlines $
      ("Evidence runs through step " <> tshow lastSeq <> ". " <> tshow (length ps) <> " lanes need work.")
      : "" : "New steps:" : map stepLine newSteps <> concatMap lane ps
  where
    lane p = "" : header p : body p
    newSteps = Map.elems (Map.fromList [ (stepSeq st, st) | p <- ps, lpCursor p /= Nothing
                                        , st <- lpCurate p <> lpCheck p ])
    stepLine st = "  " <> tshow (stepSeq st) <> maybe "" (\n -> " #" <> tshow n) (stepPr st) <> "  " <> stepTitle st
                    <> if null (stepAdrs st) then "  (no ADR changes)" else "  (ADRs " <> T.intercalate ", " (stepAdrs st) <> ")"
    header p = lpAdr p <> " " <> maybe "" id (lpTitle p) <> "  ("
      <> maybe "no lane file: create it from the founding step" (\c -> "cursor " <> tshow c) (lpCursor p) <> ")"
    body p = case lpCursor p of
      Nothing -> ["  curate: " <> steps (lpCurate p)]
      Just _ ->
        [ "  curate: " <> steps (lpCurate p) | not (null (lpCurate p)) ]
        <> [ "  realisation checks: " <> steps (lpCheck p) | not (null (lpCheck p)), not (null (lpOpen p)) ]
        <> [ "  open decisions: " <> T.intercalate ", " [nodeId n <> " " <> nodeSummary n <> progress n | n <- lpOpen p]
           | not (null (lpOpen p)), not (null (lpCurate p) && null (lpCheck p)) ]
        <> [ "  nothing to curate and no open decisions: advance the cursor" | null (lpCurate p), null (lpOpen p) ]
        <> [ "  if no listed step realises an open decision: advance the cursor" | null (lpCurate p), not (null (lpOpen p)) ]
    progress n = if null (deliveries n) then "" else " (in progress since step " <> tshow (minimum (map deliverySeq (deliveries n))) <> ")"
    steps ss = T.intercalate ", " [tshow (stepSeq s) <> maybe "" (\n -> " (#" <> tshow n <> ")") (stepPr s) | s <- ss]

pendingJson :: Int -> [LanePending] -> Value
pendingJson lastSeq ps = object
  [ "lastSeq" .= lastSeq
  , "lanes" .= [ object
      [ "adr" .= lpAdr p, "title" .= lpTitle p, "cursor" .= lpCursor p
      , "curate" .= map step (lpCurate p), "realisationChecks" .= map step (lpCheck p)
      , "open" .= [ object ["id" .= nodeId n, "summary" .= nodeSummary n, "deliveries" .= map deliverySeq (deliveries n)]
                  | n <- lpOpen p ] ]
    | p <- ps ] ]
  where step s = object ["seq" .= stepSeq s, "pr" .= stepPr s, "title" .= stepTitle s]

tshow :: Show a => a -> Text
tshow = T.pack . show
