module Evolution where

import Kyyn.Workspace.Evolution
import Kyyn.Schema
import qualified TodoSchemaV2 as Schema
import qualified Kyyn.Workspace.After as AfterCollections

evolution :: Evolution (KnowledgeBase Schema.Root) (KnowledgeBase Schema.Root)
evolution =
  edit (Rationale "Retire the completed report." [])
    (within AfterCollections.todos $ remove (FactId "todo-001"))
