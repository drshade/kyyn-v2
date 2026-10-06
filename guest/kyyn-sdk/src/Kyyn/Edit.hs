{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
module Kyyn.Edit
  ( Edit, Collection, CollectionEdit, within, current, update, append, remove
  , get, gets, put, modify, zoom, modifying, assigning, refuse
  , module Kyyn.Optics
  ) where

import Data.Text (Text)

import Control.Monad.Trans.State.Strict (StateT(..), get, gets, put, modify)
import Control.Monad.Trans.Reader (ReaderT(..), runReaderT)
import Kyyn.Types.Diagnostic (Diagnostic(..), Severity(..), DiagnosticLocation(..))
import Kyyn.Types.Evolution (EvolutionFailure(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Optics
import Kyyn.Edit.Internal (Collection(..))

-- | A state edit that can fail with evolution diagnostics.
type Edit s = StateT s (Either EvolutionFailure)
-- | Edits to one fact collection, selected with within.
type CollectionEdit a = ReaderT Text (Edit [Fact a])

-- | Stop this edit with diagnostics; no partial edited value is returned.
refuse :: [Diagnostic] -> Edit s a
refuse diagnostics = StateT (\_ -> Left (EvolutionFailure diagnostics))

-- | Run an edit against a nested part of the state selected by an optic.
zoom :: Lens' s a -> Edit a r -> Edit s r
zoom optic action = StateT $ \source -> do
  (result, target) <- runStateT action (view optic source)
  pure (result, set optic target source)

-- | Transform a nested value selected by an optic.
modifying :: Lens' s a -> (a -> a) -> Edit s ()
modifying optic transform = modify (over optic transform)

-- | Replace a nested value selected by an optic.
assigning :: Lens' s a -> a -> Edit s ()
assigning optic value = modify (set optic value)

-- | Run fact operations inside a collection selected from the root.
-- Use the collection handles exported by Kyyn.Workspace.Before or Kyyn.Workspace.After.
within :: Collection root a -> CollectionEdit a r -> Edit root r
within (Collection name optic) action = zoom optic (runReaderT action name)

-- | Read a fact's payload by ID. Fails if the ID is missing or ambiguous.
current :: FactId -> CollectionEdit a a
current selected = ReaderT $ \name -> StateT $ \facts -> do
  payload <- unique name selected facts
  pure (payload, facts)

-- | Modify one fact's payload by its ID, keeping the ID unchanged.
-- Fails if the ID is missing or ambiguous.
update :: FactId -> Edit a r -> CollectionEdit a r
update selected action = ReaderT $ \name -> StateT $ \facts -> do
  payload <- unique name selected facts
  (result, changed) <- runStateT action payload
  pure (result, map (replace changed) facts)
  where
    replace changed fact@(Fact ident _)
      | ident == selected = Fact ident changed
      | otherwise = fact

-- | Remove one fact by ID. Fails if the ID is missing or ambiguous.
remove :: FactId -> CollectionEdit a ()
remove selected = ReaderT $ \name -> StateT $ \facts -> do
  _ <- unique name selected facts
  pure ((), filter (\(Fact ident _) -> ident /= selected) facts)

-- | Append a new fact. Fails if its ID already exists in the collection.
append :: Fact a -> CollectionEdit a ()
append fact@(Fact selected _) = ReaderT $ \name -> StateT $ \facts ->
  if any (\(Fact ident _) -> ident == selected) facts
    then Left (factFailure name selected "edit.fact-duplicate" "Fact already exists")
    else Right ((), facts ++ [fact])

unique :: Text -> FactId -> [Fact a] -> Either EvolutionFailure a
unique name selected facts = case [value | Fact ident value <- facts, ident == selected] of
  [value] -> Right value
  [] -> Left (factFailure name selected "edit.fact-missing" "Fact does not exist")
  _ -> Left (factFailure name selected "edit.fact-ambiguous" "More than one fact has this ID")

factFailure :: Text -> FactId -> Text -> Text -> EvolutionFailure
factFailure collection (FactId ident) diagnosticCode description = EvolutionFailure
  [Diagnostic Error diagnosticCode (description <> ": " <> ident)
    (Just (FactLocation collection ident Nothing))]
