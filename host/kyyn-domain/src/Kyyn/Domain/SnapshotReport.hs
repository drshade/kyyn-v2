-- | Reports retain inferred stored types and values, without an old Root contract.
module Kyyn.Domain.SnapshotReport
  ( StepOrigin(..), SnapshotObservation(..), SnapshotStep(..), SnapshotChange(..)
  , checkSnapshotContinuity, snapshotChanges, equivalentSnapshots
  ) where

import Control.Monad (unless)
import Data.List (nub, sort)
import Data.Text (Text)
import Kyyn.Domain.StoredSnapshot
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Types.Evolution (Rationale)
import Kyyn.Types.Fact (Fact(..), FactId(..))

data StepOrigin = Authored | TargetProjection deriving (Eq, Show)
data SnapshotObservation = SnapshotObservation StepOrigin Rationale StoredSnapshot StoredSnapshot
  deriving (Eq, Show)
data SnapshotStep = SnapshotStep StepOrigin Rationale [SnapshotChange] deriving (Eq, Show)
data SnapshotChange
  = SnapshotFactChange Text FactId (Maybe RecordedValue) (Maybe RecordedValue)
  | SnapshotFieldChange Text (Maybe RecordedValue) (Maybe RecordedValue)
  | SnapshotMembershipChange Text (Maybe [FactId]) (Maybe [FactId])
  | SnapshotRecipeChange FactId (Maybe RecordedRecipe) (Maybe RecordedRecipe)
  deriving (Eq, Show)

-- The caller independently checks every snapshot and supplies the checked target
-- projection and encoded candidate. This function never trusts guest change IDs.
checkSnapshotContinuity :: Rationale -> StoredSnapshot -> StoredSnapshot -> StoredSnapshot
  -> [SnapshotObservation] -> Either [Diagnostic] [SnapshotStep]
checkSnapshotContinuity explanation input projected candidate observations = do
  let projections = [(reason,after) | SnapshotObservation TargetProjection reason _ after <- observations]
  case projections of
    [(reason,after)] -> do
      unless (reason == explanation) (bad "Target projection rationale differs from workspace explanation")
      unless (equivalentSnapshots after projected) (bad "Target projection differs from independently checked material")
    _ -> bad "Expected exactly one target projection observation"
  let starts = [before | SnapshotObservation _ _ before _ <- observations] ++ [candidate]
      ends = input : [after | SnapshotObservation _ _ _ after <- observations]
  mapM_ (\(index,before,after) -> unless (equivalentSnapshots before after)
    (bad ("Discontinuous observation boundary " ++ show index))) (zip3 [1 :: Int ..] ends starts)
  pure [SnapshotStep origin reason (snapshotChanges before after) |
    SnapshotObservation origin reason before after <- observations]
  where bad = Left . pure . errorDiagnostic "evolution.observation"

-- Map order and Dhall formatting carry no meaning. Membership order does.
equivalentSnapshots :: StoredSnapshot -> StoredSnapshot -> Bool
equivalentSnapshots before after = null (snapshotChanges before after)

snapshotChanges :: StoredSnapshot -> StoredSnapshot -> [SnapshotChange]
snapshotChanges (StoredSnapshot oldFields oldCollections oldRecipes) (StoredSnapshot newFields newCollections newRecipes) =
  [SnapshotFieldChange name old new | name <- keys oldFields newFields,
    let old = lookup name oldFields, let new = lookup name newFields, not (sameValue old new)] ++
  concat [collectionChanges name | name <- keys oldCollections newCollections] ++
  [SnapshotRecipeChange (FactId name) old new | name <- keys earlierRecipes laterRecipes,
    let old = lookup name earlierRecipes, let new = lookup name laterRecipes, not (sameRecipe old new)]
  where
    earlierRecipes = [(name,value) | Fact (FactId name) value <- oldRecipes]
    laterRecipes = [(name,value) | Fact (FactId name) value <- newRecipes]
    collectionChanges name =
      let before = lookup name oldCollections
          after = lookup name newCollections
          members = fmap (map (\(Fact ident _) -> ident))
          facts = maybe [] (map (\(Fact (FactId ident) value) -> (ident,value)))
      in [SnapshotMembershipChange name (members before) (members after) | members before /= members after] ++
        [SnapshotFactChange name (FactId identity) old new | identity <- keys (facts before) (facts after),
          let old = lookup identity (facts before), let new = lookup identity (facts after), not (sameValue old new)]

keys :: Ord key => [(key,a)] -> [(key,b)] -> [key]
keys before after = sort (nub (map fst before ++ map fst after))

sameValue :: Maybe RecordedValue -> Maybe RecordedValue -> Bool
sameValue (Just (RecordedValue oldShape old)) (Just (RecordedValue newShape new)) =
  case (storageShape oldShape,storageShape newShape) of
    (Right before,Right after) -> before == after && old == new
    _ -> False
sameValue before after = before == after

sameRecipe :: Maybe RecordedRecipe -> Maybe RecordedRecipe -> Bool
sameRecipe (Just (RecordedRecipe before old)) (Just (RecordedRecipe after new)) =
  before == after && sameValue (Just old) (Just new)
sameRecipe before after = before == after
