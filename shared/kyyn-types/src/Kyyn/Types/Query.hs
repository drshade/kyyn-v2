{-# LANGUAGE GADTs, ScopedTypeVariables #-}
module Kyyn.Types.Query
  ( Query(..), SnapshotRead(..), CollectionBinding(..), ReadAccess(..)
  , readCollection, readFact, runLocally
  ) where

import Data.List (find)
import Kyyn.Types.Fact (Fact(..), FactId)
import Kyyn.Types.Program (Program(..), request)

data CollectionBinding root fact = CollectionBinding String (root -> [Fact fact])

data SnapshotRead root a where
  ReadCollection :: CollectionBinding root fact -> SnapshotRead root [Fact fact]
  ReadFact :: CollectionBinding root fact -> FactId -> SnapshotRead root (Maybe (Fact fact))

newtype Query root a = Query (Program (SnapshotRead root) a)

instance Functor (Query root) where
  fmap f (Query program) = Query (fmap f program)

instance Applicative (Query root) where
  pure = Query . pure
  Query f <*> Query a = Query (f <*> a)

instance Monad (Query root) where
  Query program >>= f = Query (program >>= \value -> case f value of Query next -> next)

data ReadAccess = CollectionRead String | FactRead String FactId deriving (Eq, Show)

readCollection :: CollectionBinding root fact -> Query root [Fact fact]
readCollection = Query . request . ReadCollection

readFact :: CollectionBinding root fact -> FactId -> Query root (Maybe (Fact fact))
readFact binding = Query . request . ReadFact binding

runLocally :: forall root a. root -> Program (SnapshotRead root) a -> (a, [ReadAccess])
runLocally root = go
  where
    go :: Program (SnapshotRead root) b -> (b, [ReadAccess])
    go (Pure value) = (value, [])
    go (Request operation next) = case operation of
      ReadCollection (CollectionBinding name select) ->
        let (value, trace) = go (next (select root)) in (value, CollectionRead name : trace)
      ReadFact (CollectionBinding name select) identity ->
        let found = find (\(Fact factId _) -> factId == identity) (select root)
            (value, trace) = go (next found)
        in (value, FactRead name identity : trace)
