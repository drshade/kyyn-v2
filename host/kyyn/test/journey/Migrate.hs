{-# LANGUAGE OverloadedStrings #-}
module Evolution where

import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified Input.Todo as Input
import qualified TodoSchemaV2 as Target
import qualified Kyyn.Workspace.Target as Collections

evolution :: Evolution Target.Root
evolution = prepare
  (migrateCollection (Rationale "Track completion only; unfinished work remains Open." [])
    "todos" Collections.todos
    (traverse (\(Fact identity (Input.Todo title status)) -> Right
      (Fact identity (Target.Todo title (case status of Input.Done -> Target.Done; _ -> Target.Open))))))
  (edit (Rationale "The sales report is complete; make its title specific." [])
    (within Collections.todos $ update (FactId "todo-001") $
      put (Target.Todo "Write sales report λ" Target.Done))
  <> edit (Rationale "Review the completed report before sharing it." [])
    (within Collections.todos $
      append (Fact (FactId "todo-003") (Target.Todo "Review sales report" Target.Open))))
