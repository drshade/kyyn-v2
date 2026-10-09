-- | Load the evidence and curated layers, and validate curated lanes against the
-- evidence they were curated from. Errors make the data unrenderable; warnings
-- flag curation worth a second look. Agents run @check@ before finishing.
{-# LANGUAGE OverloadedStrings #-}
module AdrViewer.Check
  ( Inputs(..), Severity(..), Diagnostic(..)
  , loadInputs, checkInputs, checkLane, renderDiagnostic
  ) where

import AdrViewer.Json (readJson)
import AdrViewer.Model (liveUntil, realisedAt)
import AdrViewer.Types
import Control.Monad (forM)
import Data.List (group, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeBaseName, takeExtension, (</>))

data Inputs = Inputs { inRepo :: Repo, inSteps :: [Step], inAdrs :: [Adr], inLanes :: [(FilePath, Lane)] }

data Severity = Warning | Error deriving (Eq, Ord, Show)

data Diagnostic = Diagnostic { dSeverity :: Severity, dWhere :: Text, dMessage :: Text } deriving (Eq, Show)

loadInputs :: FilePath -> FilePath -> IO (Either [String] Inputs)
loadInputs evidence curated = do
  repo <- readJson (evidence </> "repo.json")
  steps <- readJson (evidence </> "steps.json")
  adrs <- readJson (evidence </> "adrs.json")
  let laneDir = curated </> "lanes"
  exists <- doesDirectoryExist laneDir
  files <- if exists then filter ((== ".json") . takeExtension) <$> listDirectory laneDir else pure []
  lanes <- forM (sort files) $ \f -> fmap ((,) f) <$> readJson (laneDir </> f)
  pure $ case (repo, steps, adrs, sequence lanes) of
    (Right r, Right s, Right a, Right l) -> Right (Inputs r s a l)
    (r, s, a, l) -> Left (lefts' r <> lefts' s <> lefts' a <> lefts' l)
  where lefts' = either pure (const [])

checkInputs :: Inputs -> [Diagnostic]
checkInputs i = concatMap (uncurry (checkLane (inSteps i) (inAdrs i))) (inLanes i)

checkLane :: [Step] -> [Adr] -> FilePath -> Lane -> [Diagnostic]
checkLane steps adrs file lane = concat
  [ [err "file name does not match its adr" | takeBaseName file /= T.unpack adr]
  , [err ("ADR " <> adr <> " is not in evidence/adrs.json") | adr `notElem` map adrId adrs]
  , [err ("cursor " <> tshow cursor <> " is beyond the last step " <> tshow lastSeq) | cursor > lastSeq]
  , [warn ("cursor is " <> tshow (lastSeq - cursor) <> " steps behind the evidence") | cursor < lastSeq]
  , [err ("duplicate node id " <> d) | (d : _ : _) <- group (sort (map nodeId nodes))]
  , concatMap checkNode nodes
  , [ err ("editorial step " <> tshow (editorialSeq e) <> " is beyond the cursor") | e <- laneEditorial lane, editorialSeq e > cursor ]
  , [ err ("step " <> tshow s <> " changed this ADR but is neither a node seq nor editorial")
    | s <- touched, s <= cursor, s `Set.notMember` covered ] ]
  where
    adr = laneAdr lane
    cursor = laneCursor lane
    nodes = laneNodes lane
    lastSeq = maybe 0 stepSeq (lastMaybe steps)
    byId = Map.fromList [(nodeId n, n) | n <- nodes]
    touched = [stepSeq s | s <- steps, adr `elem` stepAdrs s]
    covered = Set.fromList (map nodeSeq nodes <> map editorialSeq (laneEditorial lane))
    loc = T.pack file
    err = Diagnostic Error loc
    warn = Diagnostic Warning loc
    checkNode n = concat
      [ [nerr "id should be <adr>.<number>" | not (validId (nodeId n))]
      , [nerr ("seq " <> tshow (nodeSeq n) <> " is beyond the cursor") | nodeSeq n > cursor]
      , [nwarn ("seq " <> tshow (nodeSeq n) <> " is not a step that changed this ADR") | nodeSeq n `notElem` touched]
      , case (nodeKind n, nodeSupersedes n) of
          (New, _ : _) -> [nerr "a new node supersedes nothing"]
          (k, []) | k /= New -> [nerr (T.toLower (tshow k) <> " must name the node it supersedes")]
          _ -> []
      , concat [ case Map.lookup p byId of
                   Nothing -> [nerr ("supersedes unknown node " <> p)]
                   Just o | nodeSeq o > nodeSeq n -> [nerr ("supersedes " <> p <> ", which is later")]
                   _ -> []
               | p <- nodeSupersedes n ]
      , realisation n
      , [ nwarn ("replaces " <> p <> ", which has no ended") | nodeKind n == Replace, p <- nodeSupersedes n
        , Just o <- [Map.lookup p byId], isNothing (nodeEnded o) ]
      , [ nwarn ("replaces " <> p <> ", which is ended by " <> b) | nodeKind n == Replace, p <- nodeSupersedes n
        , Just o <- [Map.lookup p byId], Just e <- [nodeEnded o], Just b <- [endedBy e], b /= nodeId n
        , maybe True ((/= Replace) . nodeKind) (Map.lookup b byId) || p `notElem` maybe [] nodeSupersedes (Map.lookup b byId) ]
      , [ nwarn ("ended by " <> b <> ", which does not list it in supersedes") | Just e <- [nodeEnded n], Just b <- [endedBy e]
        , Just o <- [Map.lookup b byId], nodeId n `notElem` nodeSupersedes o ]
      , [ nwarn ("realised.seq " <> tshow s <> " is beyond the last step") | Just s <- [realisedSeq (nodeRealised n)], s > lastSeq ]
      , concatMap delivery (deliveries n)
      , [ nwarn ("delivery at step " <> tshow d <> " is listed twice") | (d : _ : _) <- group (sort (map deliverySeq (deliveries n))) ]
      , case nodeEnded n of
          Nothing -> []
          Just e -> concat
            [ [nerr "ends before it is born" | endedSeq e < nodeSeq n]
            , [nerr ("ended by unknown node " <> b) | Just b <- [endedBy e], Map.notMember b byId]
            , [nwarn "replaced without naming the replacement" | endedHow e == Replaced, isNothing (endedBy e)] ] ]
      where
        nerr = err . ((nodeId n <> ": ") <>)
        nwarn = warn . ((nodeId n <> ": ") <>)
        delivery (Delivery d _) = concat
          [ [nwarn ("delivery at step " <> tshow d <> " is beyond the last step") | d > lastSeq]
          , [ nwarn ("delivery at step " <> tshow d <> " is not before its realisation at step " <> tshow r)
            | Just r <- [realisedAt n], max (nodeSeq n) d >= r ]
          , [ nwarn ("delivery at step " <> tshow d <> " is after it stopped being live at step " <> tshow u)
            | Just u <- [liveUntil nodes n], d > u ] ]
        realisation m = let r = nodeRealised m in case (realisedHow r, realisedSeq r) of
          (LaterStep, Nothing) -> [nerr "later_step needs realised.seq"]
          (CodeFirst, Nothing) -> [nerr "code_first needs realised.seq"]
          (LaterStep, Just s) | s < nodeSeq m -> [nwarn "later_step realised before the node was born"]
          (CodeFirst, Just s) | s > nodeSeq m -> [nwarn "code_first realised after the node was born"]
          _ -> []
    validId i = case T.splitOn "." i of
      [a, num] -> a == adr && not (T.null num) && T.all (`elem` ['0' .. '9']) num
      _ -> False
    lastMaybe xs = if null xs then Nothing else Just (last xs)

renderDiagnostic :: Diagnostic -> Text
renderDiagnostic d = (if dSeverity d == Error then "error: " else "warning: ") <> dWhere d <> ": " <> dMessage d

tshow :: Show a => a -> Text
tshow = T.pack . show
