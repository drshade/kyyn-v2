{-# LANGUAGE OverloadedStrings #-}
module Evolution where

import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified SchemaV1 as Before
import qualified SchemaV2 as After
import qualified Kyyn.Workspace.Before as BeforeCollections
import qualified Kyyn.Workspace.After as AfterCollections

evolution :: Evolution (KnowledgeBase Before.Root) (KnowledgeBase After.Root)
evolution =
  editBefore (Rationale "Rename" [])
    (within BeforeCollections.todos $ update (FactId "todo-001") $
      modify (\todo -> todo { Before.title = Before.title todo ++ " λ" }))
  >=> evolve (Rationale "Add completion status" [])
    (onFacts (\(Before.Root items) -> Right (After.Root [Fact identity (After.Todo title False) | Fact identity (Before.Todo title) <- items])))
  >=> edit (Rationale "Complete the review" [])
    (within AfterCollections.todos $ do
      todo <- current (FactId "todo-001")
      update (FactId "todo-001") $ put todo { After.done = True })
