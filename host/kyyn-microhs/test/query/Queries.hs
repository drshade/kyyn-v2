module Queries where

import KyynQueryBindings
import Kyyn.Query (readCollection, readFact)
import Kyyn.Schema
import qualified Schema

ownerOf :: Schema.Input -> Query Schema.Result
ownerOf requested = do
  todos <- readCollection tasks
  case [owner | Fact _ (Schema.Todo title owner) <- todos, title == requested] of
    [] -> pure Nothing
    owner:_ -> do
      person <- readFact people owner
      pure (case person of Just (Fact _ value) -> Just value; Nothing -> Nothing)
