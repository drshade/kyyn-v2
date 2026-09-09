module Evolution where

import Kyyn.Evolution
import Kyyn.Types.Fact
import Kyyn.Types.Diagnostic (errorDiagnostic)
import Kyyn.Types.Program (Program)
import KyynEvolutionBindings
import qualified TodoSchemaV1 as Before
import qualified TodoSchemaV2 as After

evolution :: Before.Root -> Program calls (Either EvolutionFailure (EvolutionOutput After.Root))
evolution = pure . evaluateEvolution
  (evolve beforeRoot afterRoot (Rationale "Track completion only; unfinished work remains Open." [])
    (\(Before.Root facts) -> Right (After.Root
      [Fact identity (After.Todo title (case status of Before.Done -> After.Done; _ -> After.Open))
      | Fact identity (Before.Todo title status) <- facts]))
  >=> evolve afterRoot afterRoot (Rationale "The sales report is complete; make its title specific." [])
    (\(After.Root facts) -> if not (any (\(Fact identity _) -> identity == FactId "todo-001") facts)
      then Left (EvolutionFailure [errorDiagnostic "todo.missing" "Cannot complete the missing report."])
      else Right (After.Root
      [if identity == FactId "todo-001" then Fact identity (After.Todo "Write sales report λ" After.Done)
       else fact | fact@(Fact identity _) <- facts]))
  >=> evolve afterRoot afterRoot (Rationale "Review the completed report before sharing it." [])
    (\(After.Root facts) -> if any (\(Fact identity _) -> identity == FactId "todo-003") facts
      then Left (EvolutionFailure [errorDiagnostic "todo.duplicate" "The review already exists."])
      else Right (After.Root (facts ++
      [Fact (FactId "todo-003") (After.Todo "Review sales report" After.Open)]))))
