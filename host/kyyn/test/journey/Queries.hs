module Queries where

import qualified Data.Text as Text

import KyynQueryBindings
import Kyyn.Query (readFact)
import Kyyn.Schema
import qualified TodoSchemaV1 as Schema

type Input = String
type Result = String
type DoneResult = Bool

metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] []

titleFor :: Input -> Query Result
titleFor identity = do
  found <- readFact todos (FactId (Text.pack identity))
  pure (case found of Just (Fact _ (Schema.Todo title _)) -> title; Nothing -> "")

isDone :: Input -> Query DoneResult
isDone identity = do
  found <- readFact todos (FactId (Text.pack identity))
  pure (case found of Just (Fact _ (Schema.Todo _ Schema.Done)) -> True; _ -> False)
