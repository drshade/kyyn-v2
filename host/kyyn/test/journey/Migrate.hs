module Evolution where

import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified TodoSchemaV1 as Before
import qualified TodoSchemaV2 as After
import qualified Kyyn.Workspace.After as AfterCollections

evolution :: Evolution Before.Root After.Root
evolution =
  evolve (Rationale "Track completion only; unfinished work remains Open." [])
    (\(Before.Root facts) -> Right (After.Root
      [Fact identity (After.Todo title (case status of Before.Done -> After.Done; _ -> After.Open))
      | Fact identity (Before.Todo title status) <- facts]))
  >=> edit (Rationale "The sales report is complete; make its title specific." [])
    (within AfterCollections.todos $ update (FactId "todo-001") $
      put (After.Todo "Write sales report λ" After.Done))
  >=> edit (Rationale "Review the completed report before sharing it." [])
    (within AfterCollections.todos $
      append (Fact (FactId "todo-003") (After.Todo "Review sales report" After.Open)))
