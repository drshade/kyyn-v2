module Evolution where

import Kyyn.Workspace.Evolution
import qualified SchemaV1 as Before
import qualified SchemaV2 as After

evolution :: Evolution Before.Root After.Root
evolution =
  editBefore (Rationale "Rename" [])
    (\(Before.Root facts) -> Right (Before.Root [Fact identity (Before.Todo (title ++ " λ")) | Fact identity (Before.Todo title) <- facts]))
  >=> evolve (Rationale "Add completion status" [])
    (\(Before.Root facts) -> Right (After.Root [Fact identity (After.Todo title False) | Fact identity (Before.Todo title) <- facts]))
  >=> editAfter (Rationale "Complete the review" [])
    (\(After.Root facts) -> Right (After.Root [Fact identity (After.Todo title True) | Fact identity (After.Todo title _) <- facts]))
