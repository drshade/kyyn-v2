module Kyyn.Domain.Curation
  ( RecipeId(..), Recipe(..), EvidenceSelection(..), CurationRegister
  , PendingEvidence(..), CurationProblem(..)
  , emptyCurationRegister, acknowledgeEvidence, pendingEvidence
  ) where

import Data.List (nub)
import Kyyn.Domain.Evidence

newtype RecipeId = RecipeId String deriving (Eq, Show)
data Recipe = Recipe { name :: RecipeId, instructions :: String } deriving (Eq, Show)
data EvidenceSelection = EntireBatch | IndividualRecords [EvidenceId] deriving (Eq, Show)

data Progress = Progress EvidenceProducer [(EvidenceId, EvidenceFingerprint)] deriving (Eq, Show)
newtype CurationRegister = CurationRegister [((RecipeId, ConnectorInstanceRef), Progress)] deriving (Eq, Show)
data PendingEvidence = PendingEvidence EvidenceSnapshotRef [(EvidenceId, ChangeKind)] deriving (Eq, Show)
data CurationProblem = CurationProducerChanged | InvalidCurationCapture String deriving (Eq, Show)

emptyCurationRegister :: CurationRegister
emptyCurationRegister = CurationRegister []

-- The supplied capture is the resolved declaration scope, not a lookup of latest.
acknowledgeEvidence :: RecipeId -> EvidenceSelection -> CurrentEvidence
  -> CurationRegister -> Either CurationProblem CurationRegister
acknowledgeEvidence recipe selection capture@(CurrentEvidence (EvidenceSnapshotRef instanceRef producer _) _) (CurationRegister entries) = do
  current <- fingerprints capture
  let key = (recipe, instanceRef)
      prior = lookup key entries
  next <- case selection of
    EntireBatch -> Right current
    IndividualRecords ids -> do
      old <- compatible producer prior
      pure ([(item, token) | (item, token) <- old, item `notElem` ids]
        ++ [(item, token) | (item, token) <- current, item `elem` ids])
  pure (CurationRegister (replace key (Progress producer next) entries))

pendingEvidence :: RecipeId -> CurationRegister -> CurrentEvidence
  -> Either CurationProblem PendingEvidence
pendingEvidence recipe (CurationRegister entries) capture@(CurrentEvidence snapshot@(EvidenceSnapshotRef instanceRef producer _) _) = do
  current <- fingerprints capture
  old <- compatible producer (lookup (recipe, instanceRef) entries)
  let present = [(item, maybe New (const Updated) (lookup item old)) |
        (item, token) <- current, lookup item old /= Just token]
      removed = [(item, Removed) | (item, _) <- old, lookup item current == Nothing]
  pure (PendingEvidence snapshot (present ++ removed))

compatible :: EvidenceProducer -> Maybe Progress
  -> Either CurationProblem [(EvidenceId, EvidenceFingerprint)]
compatible _ Nothing = Right []
compatible producer (Just (Progress previous items))
  | producer == previous = Right items
  | otherwise = Left CurationProducerChanged

fingerprints :: CurrentEvidence -> Either CurationProblem [(EvidenceId, EvidenceFingerprint)]
fingerprints (CurrentEvidence _ items)
  | length keys /= length (nub keys) = Left (InvalidCurationCapture "Duplicate evidence IDs")
  | any invalid values = Left (InvalidCurationCapture "Empty evidence ID or fingerprint")
  | otherwise = Right values
  where
    values = [(item, token) | (item, Evidence token _ _) <- items]
    keys = map fst values
    invalid (EvidenceId item, EvidenceFingerprint token) = null item || null token

replace :: Eq k => k -> v -> [(k,v)] -> [(k,v)]
replace key value [] = [(key,value)]
replace key value ((k,v):rest)
  | key == k = (key,value):rest
  | otherwise = (k,v):replace key value rest
