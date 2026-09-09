module Evolution where

import Kyyn.Workspace.Evolution
import qualified TodoSchemaV2 as Schema

evolution :: Evolution Schema.Root Schema.Root
evolution =
  editAfter (Rationale "Retire the completed report." [])
    (\(Schema.Root facts) -> Right (Schema.Root
      [fact | fact@(Fact identity _) <- facts, identity /= FactId "todo-001"]))
