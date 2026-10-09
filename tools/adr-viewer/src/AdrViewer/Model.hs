-- | What the viewer shows at each step, derived purely from curated lanes.
--
-- A node is born at its step and never changes colour backwards: specified, then
-- in progress once a step delivers part of it, then realised. It is live until
-- it ends or a later node supersedes it (a refinement continues the decision; a
-- replacement ends it). Deliveries and realisation count only while it is still
-- live. The browser only compares these numbers with the step being shown; every
-- rule lives here.
module AdrViewer.Model
  ( NodeView(..), LaneView(..), State(..), Counts(..), Share(..)
  , realisedAt, deliveredAt, liveUntil, assignTracks, laneView, stateAt, convergence
  ) where

import AdrViewer.Types
import Data.List (nub, sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)

data NodeView = NodeView
  { nvNode :: Node
  , nvUntil :: Maybe Int       -- ^ step at which it stops being live; Nothing while current
  , nvRealisedAt :: Maybe Int  -- ^ step from which the code realises it; Nothing if never
  , nvDeliveredAt :: [Int]     -- ^ steps that delivered part of it, before 'nvRealisedAt'
  , nvTrack :: Int }           -- ^ row within the lane; successors inherit their predecessor's
  deriving (Eq, Show)

data LaneView = LaneView
  { lvLane :: Lane, lvNodes :: [NodeView], lvDepth :: Int
  , lvCounts :: [Counts] }     -- ^ live decisions per step 0..max
  deriving (Eq, Show)

-- | Live decisions at one step, by how far the code has got.
data Counts = Counts { cDone :: Int, cPartial :: Int, cPlanned :: Int } deriving (Eq, Show)

instance Semigroup Counts where
  Counts a b c <> Counts d e f = Counts (a + d) (b + e) (c + f)

instance Monoid Counts where
  mempty = Counts 0 0 0

-- | Shares of the live decisions across all lanes at one step.
data Share = Share { shareDone :: Double, sharePartial :: Double } deriving (Eq, Show)

data State = Hidden | Planned | Partial | Done | PlannedEnded | PartialEnded | DoneEnded
  deriving (Eq, Show)

realisedAt :: Node -> Maybe Int
realisedAt n = case realisedHow (nodeRealised n) of
  SameStep -> Just (nodeSeq n)
  LaterStep -> max (nodeSeq n) <$> realisedSeq (nodeRealised n)
  CodeFirst -> max (nodeSeq n) <$> realisedSeq (nodeRealised n)
  Unrealised -> Nothing
  Unknown -> Nothing

-- | Steps delivering part of it, never earlier than its birth (code that predates
-- the decision shows as progress when it is written down) and only those before
-- it is realised.
deliveredAt :: Node -> [Int]
deliveredAt n = nub (sort [d | Delivery s _ <- deliveries n, let d = max (nodeSeq n) s, maybe True (d <) (realisedAt n)])

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
    views = [ NodeView n (liveUntil nodes n) (realisedAt n) (deliveredAt n) (Map.findWithDefault 0 (nodeId n) tracks)
            | n <- nodes ]
    depth = max 1 (1 + maximum (0 : map nvTrack views))
    counts = [foldMap (count . stateAt s) views | s <- [0 .. maxSeq]]
    count Done = Counts 1 0 0
    count Partial = Counts 0 1 0
    count Planned = Counts 0 0 1
    count _ = mempty

stateAt :: Int -> NodeView -> State
stateAt t v
  | nodeSeq (nvNode v) > t = Hidden
  | built = if ended then DoneEnded else Done
  | started = if ended then PartialEnded else Partial
  | otherwise = if ended then PlannedEnded else Planned
  where
    ended = maybe False (<= t) (nvUntil v)
    horizon = maybe t (min t) (nvUntil v)
    built = maybe False (<= horizon) (nvRealisedAt v)
    started = any (<= horizon) (nvDeliveredAt v)

-- | Per step, the shares of live curated decisions the code realises and has
-- started on.
convergence :: [LaneView] -> [Maybe Share]
convergence [] = []
convergence lanes = map share (foldr1 (zipWith (<>)) (map lvCounts lanes))
  where
    share (Counts done partial planned)
      | total == 0 = Nothing
      | otherwise = Just (Share (fromIntegral done / fromIntegral total) (fromIntegral partial / fromIntegral total))
      where total = done + partial + planned
