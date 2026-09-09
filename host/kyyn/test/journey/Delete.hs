module Evolution where

import Kyyn.Evolution
import Kyyn.Types.Fact
import Kyyn.Types.Program (Program)
import KyynEvolutionBindings
import qualified TodoSchemaV2 as Schema

evolution :: Schema.Root -> Program calls (Either EvolutionFailure (EvolutionOutput Schema.Root))
evolution = pure . evaluateEvolution
  (evolve beforeRoot afterRoot (Rationale "Retire the completed report." [])
    (\(Schema.Root facts) -> Right (Schema.Root
      [fact | fact@(Fact identity _) <- facts, identity /= FactId "todo-001"])))
