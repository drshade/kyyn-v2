{-# LANGUAGE OverloadedStrings #-}
-- Private structural snapshot transport for the pure evolution adapter.
module Kyyn.Runtime.Snapshot (snapshotWire, fromSnapshotWire) where

import qualified Data.Text as Text
import Data.List (nub)
import Control.Monad (unless)
import Kyyn.Evolution.Stored
import Kyyn.Types.SnapshotWire
import Kyyn.Types.Fact (Fact(..), FactId(..), parseFactId)
import Kyyn.Types.KnowledgeBase (Recipe(..), FlowEntryRef(..))

snapshotWire :: StoredSnapshot -> Either String SnapshotWire
snapshotWire (StoredSnapshot fields collections recipes) = SnapshotWire
  <$> pure [(name,encode value) | (name,value) <- fields]
  <*> pure [(name,[(ident,encode value) | Fact (FactId ident) value <- members]) | (name,members) <- collections]
  <*> traverse (\(Fact (FactId name) (StoredRecipe method selected value)) -> do
    definition <- case (method,selected) of
      (OpenAgent instructions,Just stateType) -> Right (OpenWire instructions stateType)
      (ClosedAgent (FlowEntryRef flow),Nothing) -> Right (ClosedWire flow)
      _ -> Left "Invalid recipe definition in snapshot"
    pure (name,RecipeWire definition (encode value))) recipes
  where encode (RecordedValue shape value) = ValueWire shape value

fromSnapshotWire :: SnapshotWire -> Either String StoredSnapshot
fromSnapshotWire (SnapshotWire fields collections recipes) = do
  unique "residual fields" (map fst fields)
  unique "collections" (map fst collections)
  unique "recipes" (map fst recipes)
  members <- traverse (\(name,entries) -> do
    unique "collection members" (map fst entries)
    values <- traverse (\(identity,value) -> do
      ident <- either (Left . Text.unpack) Right (parseFactId identity)
      pure (Fact ident (decode value))) entries
    pure (name,values)) collections
  states <- traverse (\(identity,RecipeWire definition value) -> do
    ident <- either (Left . Text.unpack) Right (parseFactId identity)
    let recipe = case definition of
          OpenWire instructions name -> StoredRecipe (OpenAgent instructions) (Just name) (decode value)
          ClosedWire name -> StoredRecipe (ClosedAgent (FlowEntryRef name)) Nothing (decode value)
    pure (Fact ident recipe)) recipes
  pure (StoredSnapshot [(name,decode value) | (name,value) <- fields] members states)
  where decode (ValueWire shape value) = RecordedValue shape value

unique :: Eq a => String -> [a] -> Either String ()
unique label values = unless (length values == length (nub values)) (Left ("Duplicate " ++ label))
