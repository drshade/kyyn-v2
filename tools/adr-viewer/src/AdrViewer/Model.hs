-- | What the viewer shows at each step, derived purely from curated lanes.
--
-- A node is born at its step and never changes colour backwards. It is live until
-- it ends or a later node supersedes it (a refinement continues the decision; a
-- replacement ends it). It counts as realised from 'realisedAt', but only if that
-- happens while it is still live. The browser only compares these numbers with the
-- step being shown; every rule lives here.
module AdrViewer.Model
  ( NodeView(..), LaneView(..), State(..)
  , realisedAt, liveUntil, assignTracks, laneView, stateAt, convergence
  ) where

import AdrViewer.Types
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)

data NodeView = NodeView
  { nvNode :: Node
  , nvUntil :: Maybe Int       -- ^ step at which it stops being live; Nothing while current
  , nvRealisedAt :: Maybe Int  -- ^ step from which the code realises it; Nothing if never
  , nvTrack :: Int }           -- ^ row within the lane; successors inherit their predecessor's
  deriving (Eq, Show)

data LaneView = LaneView
  { lvLane :: Lane, lvNodes :: [NodeView], lvDepth :: Int
  , lvCounts :: [(Int, Int)] } -- ^ per step 0..max: live decisions (realised, still ahead of code)
  deriving (Eq, Show)

data State = Hidden | Planned | Done | PlannedEnded | DoneEnded deriving (Eq, Show)

realisedAt :: Node -> Maybe Int
realisedAt n = case realisedHow (nodeRealised n) of
  SameStep -> Just (nodeSeq n)
  LaterStep -> max (nodeSeq n) <$> realisedSeq (nodeRealised n)
  CodeFirst -> max (nodeSeq n) <$> realisedSeq (nodeRealised n)
  Unrealised -> Nothing
  Unknown -> Nothing

-- | The earliest of its own end and any later node that supersedes it.
liveUntil :: [Node] -> Node -> Maybe Int
liveUntil nodes n = minimumMaybe (own <> successors)
  where
    own = maybe [] (pure . endedSeq) (nodeEnded n)
    successors = [nodeSeq m | m <- nodes, nodeId n `elem` nodeSupersedes m, nodeSeq m >= nodeSeq n]
    minimumMaybe [] = Nothing
    minimumMaybe xs = Just (minimum xs)

-- | A successor takes the track of the node it supersedes when that node has just
-- ended; otherwise the free track nearest its predecessor, or the lowest free one.
assignTracks :: [Node] -> Map.Map Text Int
assignTracks nodes = fst (foldl' place (Map.empty, Map.empty) (sortOn (\n -> (nodeSeq n, nodeId n)) nodes))
  where
    untilOf = Map.fromList [(nodeId n, liveUntil nodes n) | n <- nodes]
    endsBy i s = maybe False (<= s) (Map.findWithDefault Nothing i untilOf)
    place (tracks, holders) n =
      let free t = maybe True (\h -> endsBy h (nodeSeq n)) (Map.lookup t holders)
          inherited = [t | p <- nodeSupersedes n, Just t <- [Map.lookup p tracks]
                         , Map.lookup t holders == Just p, endsBy p (nodeSeq n)]
          near = fromMaybe 0 (firstJust [Map.lookup p tracks | p <- nodeSupersedes n])
          candidates = filter free [0 .. Map.size holders]
          nearest = snd (minimum [(abs (t - near), t) | t <- candidates])
          chosen = case inherited of (i : _) -> i; [] -> nearest
      in (Map.insert (nodeId n) chosen tracks, Map.insert chosen (nodeId n) holders)
    firstJust xs = case [x | Just x <- xs] of (x : _) -> Just x; [] -> Nothing

laneView :: Int -> Lane -> LaneView
laneView maxSeq lane = LaneView lane views depth counts
  where
    nodes = laneNodes lane
    tracks = assignTracks nodes
    views = [NodeView n (liveUntil nodes n) (realisedAt n) (Map.findWithDefault 0 (nodeId n) tracks) | n <- nodes]
    depth = max 1 (1 + maximum (0 : map nvTrack views))
    counts = [count s | s <- [0 .. maxSeq]]
    count s = foldl' (\(d, p) v -> case stateAt s v of
                        Done -> (d + 1, p)
                        Planned -> (d, p + 1)
                        _ -> (d, p)) (0, 0) views

stateAt :: Int -> NodeView -> State
stateAt t v
  | nodeSeq (nvNode v) > t = Hidden
  | ended = if built then DoneEnded else PlannedEnded
  | otherwise = if built then Done else Planned
  where
    ended = maybe False (<= t) (nvUntil v)
    horizon = maybe t (min t) (nvUntil v)
    built = maybe False (<= horizon) (nvRealisedAt v)

-- | Per step, the share of live curated decisions the code realises.
convergence :: [LaneView] -> [Maybe Double]
convergence [] = []
convergence lanes = map share (foldr1 (zipWith add) (map lvCounts lanes))
  where
    add (a, b) (c, d) = (a + c, b + d)
    share (done, planned)
      | done + planned == 0 = Nothing
      | otherwise = Just (fromIntegral done / fromIntegral (done + planned))
