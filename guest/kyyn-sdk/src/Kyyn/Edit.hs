{-# LANGUAGE RankNTypes #-}
module Kyyn.Edit
  ( Edit, Collection, CollectionEdit, within, current, update, append, remove
  , get, gets, put, modify, zoom, modifying, assigning, refuse
  , module Kyyn.Optics
  ) where

import Control.Monad.Trans.State.Strict (StateT(..), get, gets, put, modify)
import Control.Monad.Trans.Reader (ReaderT(..), runReaderT)
import Kyyn.Types.Diagnostic (Diagnostic(..), Severity(..), DiagnosticLocation(..))
import Kyyn.Types.Evolution (EvolutionFailure(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Optics
import Kyyn.Edit.Internal (Collection(..))

type Edit s = StateT s (Either EvolutionFailure)
type CollectionEdit a = ReaderT String (Edit [Fact a])

refuse :: [Diagnostic] -> Edit s a
refuse diagnostics = StateT (\_ -> Left (EvolutionFailure diagnostics))

zoom :: Lens' s a -> Edit a r -> Edit s r
zoom optic action = StateT $ \source -> do
  (result, target) <- runStateT action (view optic source)
  pure (result, set optic target source)

modifying :: Lens' s a -> (a -> a) -> Edit s ()
modifying optic transform = modify (over optic transform)

assigning :: Lens' s a -> a -> Edit s ()
assigning optic value = modify (set optic value)

within :: Collection root a -> CollectionEdit a r -> Edit root r
within (Collection name optic) action = zoom optic (runReaderT action name)

current :: FactId -> CollectionEdit a a
current selected = ReaderT $ \name -> StateT $ \facts -> do
  payload <- unique name selected facts
  pure (payload, facts)

update :: FactId -> Edit a r -> CollectionEdit a r
update selected action = ReaderT $ \name -> StateT $ \facts -> do
  payload <- unique name selected facts
  (result, changed) <- runStateT action payload
  pure (result, map (replace changed) facts)
  where
    replace changed fact@(Fact ident _)
      | ident == selected = Fact ident changed
      | otherwise = fact

remove :: FactId -> CollectionEdit a ()
remove selected = ReaderT $ \name -> StateT $ \facts -> do
  _ <- unique name selected facts
  pure ((), filter (\(Fact ident _) -> ident /= selected) facts)

append :: Fact a -> CollectionEdit a ()
append fact@(Fact selected _) = ReaderT $ \name -> StateT $ \facts ->
  if any (\(Fact ident _) -> ident == selected) facts
    then Left (factFailure name selected "edit.fact-duplicate" "Fact already exists")
    else Right ((), facts ++ [fact])

unique :: String -> FactId -> [Fact a] -> Either EvolutionFailure a
unique name selected facts = case [value | Fact ident value <- facts, ident == selected] of
  [value] -> Right value
  [] -> Left (factFailure name selected "edit.fact-missing" "Fact does not exist")
  _ -> Left (factFailure name selected "edit.fact-ambiguous" "More than one fact has this ID")

factFailure :: String -> FactId -> String -> String -> EvolutionFailure
factFailure collection (FactId ident) diagnosticCode description = EvolutionFailure
  [Diagnostic Error diagnosticCode (description ++ ": " ++ ident)
    (Just (FactLocation collection ident Nothing))]
