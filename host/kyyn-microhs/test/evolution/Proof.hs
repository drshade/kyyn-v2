module Proof where

import qualified EvolutionCore
import qualified Evolution
import qualified Identity
import Kyyn.Evolution
import Kyyn.Evolution.Internal (RootBinding(..), RecordedRoot(..), StepObservation(..), EvolutionOutput(..))
import Kyyn.Types.Fact
import Kyyn.Types.Program (Program(..))
import KyynEvolutionBindings
import Kyyn.Runtime.Json (parseValue)
import qualified SchemaV1 as Before
import qualified SchemaV2 as After

main :: IO ()
main = do
  EvolutionCore.main
  let input = Before.Root [Fact (FactId "todo-001") (Before.Todo "Review")]
      RootBinding oldId _ = beforeRoot
      RootBinding metadataId _ = renamedRoot
      RootBinding targetId _ = afterRoot
  case Identity.evolution input of
    Pure (Right (EvolutionOutput value observations)) -> assert (value == input && null observations)
    _ -> fail "Identity scaffold did not return the unchanged root with an empty log"
  expectedOld <- either fail pure (parseValue "{\"todos\":[{\"id\":\"todo-001\",\"value\":{\"title\":\"Review\"}}]}")
  expectedRenamed <- either fail pure (parseValue "{\"todos\":[{\"id\":\"todo-001\",\"value\":{\"title\":\"Review λ\"}}]}")
  expectedAfter <- either fail pure (parseValue "{\"todos\":[{\"id\":\"todo-001\",\"value\":{\"title\":\"Review λ\",\"done\":false}}]}")
  case Evolution.evolution input of
    Pure (Right (EvolutionOutput value observations)) -> do
      assert (value == After.Root [Fact (FactId "todo-001") (After.Todo "Review λ" False)])
      assert (oldId /= metadataId && metadataId /= targetId)
      assert (observations ==
        [ StepObservation (Rationale "Rename" []) (RecordedRoot oldId expectedOld) (RecordedRoot oldId expectedRenamed)
        , StepObservation (Rationale "Display metadata" []) (RecordedRoot oldId expectedRenamed) (RecordedRoot metadataId expectedRenamed)
        , StepObservation (Rationale "Add completion status" []) (RecordedRoot metadataId expectedRenamed) (RecordedRoot targetId expectedAfter)
        ])
    _ -> fail "Expected a pure successful evolution entry"
  putStrLn "Generated evolution bindings preserve typed schema and metadata transitions."

assert :: Bool -> IO ()
assert True = pure ()
assert False = fail "Generated binding observation mismatch"
