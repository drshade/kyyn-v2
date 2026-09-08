module Evolution where

import Kyyn.Evolution
import Kyyn.Types.Fact
import Kyyn.Types.Program (Program)
import KyynEvolutionBindings
import qualified SchemaV1 as Before
import qualified SchemaV2 as After

evolution :: Before.Root -> Program calls (Either EvolutionFailure (EvolutionOutput After.Root))
evolution = pure . evaluateEvolution change

change :: Evolution Before.Root After.Root
change =
  evolve beforeRoot beforeRoot (Rationale "Rename" [])
    (\(Before.Root facts) -> Right (Before.Root [Fact identity (Before.Todo (title ++ " λ")) | Fact identity (Before.Todo title) <- facts]))
  >=> evolve beforeRoot renamedRoot (Rationale "Display metadata" []) Right
  >=> evolve renamedRoot afterRoot (Rationale "Add completion status" [])
    (\(Before.Root facts) -> Right (After.Root [Fact identity (After.Todo title False) | Fact identity (Before.Todo title) <- facts]))
