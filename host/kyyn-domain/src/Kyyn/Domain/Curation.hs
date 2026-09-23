module Kyyn.Domain.Curation
  ( RecipeId(..), Recipe(..), Acknowledgement(..), CurationRegister
  , PendingEvidence(..), CurationProblem(..)
  , emptyCurationRegister, acknowledgeEvidence, pendingEvidence, recipeId
  , CurationEntry, curationEntries, curationRegister
  ) where

import Data.List (nub, sortOn)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Plugin (bindingName, pluginNameText, PackageIdentity(..))

newtype RecipeId = RecipeId String deriving (Eq, Show)
recipeId :: String -> Either String RecipeId
recipeId value = either (Left . ("Invalid recipe name: " ++)) (const (Right (RecipeId value))) (bindingName value)
data Recipe = Recipe { name :: RecipeId, instructions :: String } deriving (Eq, Show)
data Acknowledgement = EntireBatch | IndividualRecords [EvidenceId] deriving (Eq, Show)

data Progress = Progress EvidenceProducer [(EvidenceId, EvidenceFingerprint)] deriving (Eq, Show)
newtype CurationRegister = CurationRegister [((RecipeId, ConnectorInstanceRef), Progress)] deriving (Show)
instance Eq CurationRegister where
  left == right = curationEntries left == curationEntries right
data PendingEvidence = PendingEvidence EvidenceSnapshotRef [(EvidenceId, ChangeKind)] deriving (Eq, Show)
data CurationProblem = CurationProducerChanged | InvalidCurationCapture String deriving (Eq, Show)

type CurationEntry = (RecipeId, ConnectorInstanceRef, EvidenceProducer, [(EvidenceId, EvidenceFingerprint)])

curationEntries :: CurationRegister -> [CurationEntry]
curationEntries (CurationRegister entries) = sortOn key
  [(recipe, instanceRef, producer, sortOn itemKey items) |
    ((recipe, instanceRef), Progress producer items) <- entries]
  where
    key (RecipeId recipe, ConnectorInstanceRef plugin instanceName, _, _) =
      (recipe, pluginNameText plugin, instanceName)
    itemKey (EvidenceId item, _) = item

curationRegister :: [CurationEntry] -> Either String CurationRegister
curationRegister entries
  | length keys /= length (nub keys) = Left "Duplicate recipe/connector progress"
  | otherwise = do
      checked <- traverse entry entries
      pure (CurationRegister checked)
  where
    keys = [(recipe, instanceRef) | (recipe, instanceRef, _, _) <- entries]
    entry (recipe@(RecipeId name), instanceRef@(ConnectorInstanceRef _ instanceName), producer@(EvidenceProducer (PackageIdentity package) _), items) = do
      _ <- recipeId name
      if null instanceName || null package then Left "Empty curation instance or producer" else Right ()
      let ids = map fst items
      if length ids /= length (nub ids) || any invalid items
        then Left "Duplicate/empty acknowledged IDs or fingerprints"
        else Right ((recipe, instanceRef), Progress producer items)
    invalid (EvidenceId item, EvidenceFingerprint token) = null item || null token

emptyCurationRegister :: CurationRegister
emptyCurationRegister = CurationRegister []

-- The supplied capture is the resolved declaration scope, not a lookup of latest.
acknowledgeEvidence :: RecipeId -> Acknowledgement -> CurrentEvidence
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
