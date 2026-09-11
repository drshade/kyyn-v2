{-# LANGUAGE DuplicateRecordFields #-}
module Kyyn.Domain.Evidence
  ( EvidenceId(..), FetchId(..), ConnectorInstanceRef(..), EvidenceProducer(..)
  , Evidence(..), EvidenceChange(..), Fetch(..), EvidenceState(..), EvidenceSelection(..)
  , EvidenceSnapshotRef(..), EvidenceProblem(..), ChangeKind(..), EvidenceChangeSummary(..)
  , applyChanges, snapshotAt, fetchesBetween, summarizeChanges, validateState
  ) where

import Control.Monad (foldM, unless)
import Data.List (nub)
import Kyyn.Domain.Plugin (PluginName, pluginNameText)
import Kyyn.Domain.Contract (ContractId)
import Kyyn.Types.Evidence (EvidenceRef(..))

newtype EvidenceId = EvidenceId String deriving (Eq, Show)
newtype FetchId = FetchId String deriving (Eq, Show)
data ConnectorInstanceRef = ConnectorInstanceRef PluginName String deriving (Eq, Show)
data EvidenceProducer = EvidenceProducer String ContractId deriving (Eq, Show)
data Evidence a = Evidence [String] a deriving (Eq, Show)
data EvidenceChange a = NewEvidence EvidenceId (Evidence a)
  | UpdatedEvidence EvidenceId (Evidence a) | RemovedEvidence EvidenceId deriving (Eq, Show)
data Fetch a = Fetch
  { identity :: FetchId, previous :: Maybe FetchId, fetchedAt :: String
  , changes :: [EvidenceChange a]
  } deriving (Eq, Show)
data EvidenceState a = EvidenceState
  { baseline :: Maybe FetchId, initial :: [(EvidenceId, Evidence a)]
  , current :: Maybe FetchId, values :: [(EvidenceId, Evidence a)]
  , history :: [Fetch a]
  } deriving (Eq, Show)
data EvidenceSelection = CurrentEvidence | AtFetch FetchId deriving (Eq, Show)
data EvidenceSnapshotRef = EvidenceSnapshotRef ConnectorInstanceRef EvidenceProducer FetchId deriving (Eq, Show)
data EvidenceProblem = HistoryUnavailable | ProducerContractChanged
  | BaseSnapshotConflict | InvalidDelta String | InvalidEvidence String
  deriving (Eq, Show)
data ChangeKind = New | Updated | Removed deriving (Eq, Show)
data EvidenceChangeSummary = EvidenceChangeSummary
  { fetch :: FetchId, previous :: Maybe FetchId, kind :: ChangeKind
  , item :: EvidenceId, citation :: EvidenceRef
  } deriving (Eq, Show)

applyChanges :: [(EvidenceId, Evidence a)] -> [EvidenceChange a]
  -> Either EvidenceProblem [(EvidenceId, Evidence a)]
applyChanges = foldM step
  where
    step values change = case change of
      NewEvidence key value | missing key values -> valid key >> pure (values ++ [(key,value)])
                            | otherwise -> Left (InvalidDelta "New evidence ID already exists")
      UpdatedEvidence key value | missing key values -> Left (InvalidDelta "Updated evidence ID is missing")
                                | otherwise -> pure [(k,if k == key then value else v) | (k,v) <- values]
      RemovedEvidence key | missing key values -> Left (InvalidDelta "Removed evidence ID is missing")
                          | otherwise -> pure [(k,v) | (k,v) <- values, k /= key]
    missing key = not . any ((== key) . fst)
    valid (EvidenceId key) | null key = Left (InvalidDelta "Evidence ID must not be empty")
                          | otherwise = Right ()

snapshotAt :: EvidenceState a -> FetchId -> Either EvidenceProblem [(EvidenceId, Evidence a)]
snapshotAt (EvidenceState baseline initial current values history) target
  | current == Just target = Right values
  | otherwise = do
      selected <- through baseline history target
      foldM apply initial selected
  where
    apply members (Fetch _ _ _ changes) = applyChanges members changes

through :: Maybe FetchId -> [Fetch a] -> FetchId -> Either EvidenceProblem [Fetch a]
through baseline history target = go baseline [] history
  where
    go _ _ [] = Left HistoryUnavailable
    go expected result (entry@(Fetch identity previous _ _):rest)
      | previous /= expected = Left HistoryUnavailable
      | identity == target = Right (result ++ [entry])
      | otherwise = go (Just identity) (result ++ [entry]) rest

fetchesBetween :: EvidenceState a -> FetchId -> Maybe FetchId -> Either EvidenceProblem [Fetch a]
fetchesBetween (EvidenceState baseline _ _ _ history) target base = case base of
  Nothing | baseline == Nothing -> through Nothing history target
          | otherwise -> Left HistoryUnavailable
  Just start -> do
    rest <- after start history
    if start == target then Right [] else untilTarget (Just start) rest
  where
    after _ [] = Left HistoryUnavailable
    after key (Fetch identity _ _ _:rest) | key == identity = Right rest
                                        | otherwise = after key rest
    untilTarget _ [] = Left HistoryUnavailable
    untilTarget expected (entry@(Fetch identity previous _ _):rest)
      | previous /= expected = Left HistoryUnavailable
      | identity == target = Right [entry]
      | otherwise = (entry :) <$> untilTarget (Just identity) rest

summarizeChanges :: ConnectorInstanceRef -> [(EvidenceId, Evidence a)] -> [Fetch a]
  -> Either EvidenceProblem [EvidenceChangeSummary]
summarizeChanges (ConnectorInstanceRef plugin instanceName) initial fetches = snd <$> foldM summarize (initial,[]) fetches
  where
    summarize (values, summaries) (Fetch identity previous _ changes) =
      foldM (step identity previous) (values,summaries) changes
    step identity previous (values,summaries) change = do
      let (key@(EvidenceId source), kind, refs) = case change of
            NewEvidence changed (Evidence links _) -> (changed,New,links)
            UpdatedEvidence changed (Evidence links _) -> (changed,Updated,links)
            RemovedEvidence changed -> (changed,Removed,maybe [] (\(Evidence links _) -> links) (lookup changed values))
      next <- applyChanges values [change]
      pure (next,summaries ++ [EvidenceChangeSummary identity previous kind key
        (EvidenceRef (pluginNameText plugin) instanceName source refs)])

validateState :: Eq a => EvidenceState a -> Either EvidenceProblem ()
validateState (EvidenceState baseline initial current values history) = do
  let ids = [key | Fetch key _ _ _ <- history]
      unique members = length (map fst members) == length (nub (map fst members))
      validId (EvidenceId name,_) = not (null name)
  unless (length ids == length (nub ids) && baseline `notElem` map Just ids &&
    all (\(FetchId name) -> not (null name)) ids &&
    (baseline /= Nothing || null initial) &&
    unique initial && unique values && all validId (initial ++ values))
    (Left (InvalidEvidence "Invalid or duplicate evidence/fetch IDs in storage"))
  case reverse history of
    [] -> unless (baseline == current && initial == values) (Left (InvalidEvidence "Invalid materialized baseline"))
    Fetch latest _ _ _: _ -> do
      unless (current == Just latest) (Left (InvalidEvidence "Current fetch differs from history"))
      -- Exclude the current-value shortcut while checking the stored derivative.
      reconstructed <- snapshotAt (EvidenceState baseline initial Nothing values history) latest
      unless (values == reconstructed) (Left (InvalidEvidence "Current snapshot differs from fetch history"))
