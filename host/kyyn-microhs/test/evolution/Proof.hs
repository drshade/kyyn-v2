{-# LANGUAGE OverloadedStrings #-}
module Proof where

import qualified EvolutionCore
import qualified RecipeProof
import qualified Evolution
import qualified Identity
import qualified Kyyn.Workspace.Metadata as Metadata
import qualified Kyyn.Workspace.Unchanged as Unchanged
import Kyyn.Evolution
import Kyyn.Recipe.Internal (KnowledgeBase(..))
import Kyyn.Evolution.Internal (RecordedRoot(..), StepObservation(..), EvolutionOutput(..), evaluateEvolution)
import Kyyn.Types.Fact
import Kyyn.Runtime.Json (parseValue, record)
import Kyyn.Runtime.Evolution (encodeEvolutionReply, knowledgeBaseCodec)
import Kyyn.Types.Diagnostic
import qualified KyynEvolutionCodec1 as AfterCodec
import qualified SchemaV1 as Before
import qualified SchemaV2 as After

main :: IO ()
main = do
  EvolutionCore.main
  RecipeProof.main
  let input = KnowledgeBase (Before.Root [Fact (FactId "todo-001") (Before.Todo "Review")]) []
  case evaluateEvolution Identity.evolution input of
    Right (EvolutionOutput value observations) -> assert (value == input && null observations)
    _ -> fail "Identity scaffold did not return the unchanged root with an empty log"
  let reason = Rationale "Metadata only" []
  case evaluateEvolution (Metadata.editBefore reason (pure ()) >=> Metadata.evolve reason Right >=> Metadata.edit reason (pure ())) input of
    Right (EvolutionOutput value
      [StepObservation _ (RecordedRoot b _) (RecordedRoot b' _),
       StepObservation _ (RecordedRoot b'' _) (RecordedRoot a _),
       StepObservation _ (RecordedRoot a' _) (RecordedRoot a'' _)]) ->
         assert (value == input && b == b' && b == b'' && a == a' && a == a'' && a /= b)
    _ -> fail "Metadata-only steps lost their endpoint identities"
  case evaluateEvolution (Unchanged.editBefore reason (pure ()) >=> Unchanged.edit reason (pure ())) input of
    Right (EvolutionOutput value
      [StepObservation _ (RecordedRoot b _) (RecordedRoot b' _),
       StepObservation _ (RecordedRoot a _) (RecordedRoot a' _)]) ->
         assert (value == input && b == b' && b == a && b == a')
    _ -> fail "Same-contract edits required an unnecessary transition"
  expectedOld <- either fail pure (parseValue "{\"todos\":[{\"id\":\"todo-001\",\"value\":{\"title\":\"Review\"}}]}")
  expectedRenamed <- either fail pure (parseValue "{\"todos\":[{\"id\":\"todo-001\",\"value\":{\"title\":\"Review λ\"}}]}")
  expectedAfter <- either fail pure (parseValue "{\"todos\":[{\"id\":\"todo-001\",\"value\":{\"title\":\"Review λ\",\"done\":false}}]}")
  expectedFinal <- either fail pure (parseValue "{\"todos\":[{\"id\":\"todo-001\",\"value\":{\"title\":\"Review λ\",\"done\":true}}]}")
  case evaluateEvolution Evolution.evolution input of
    Right (EvolutionOutput value observations@(StepObservation _ (RecordedRoot oldId _) _ : StepObservation _ _ (RecordedRoot targetId _) : _)) -> do
      assert (value == KnowledgeBase (After.Root [Fact (FactId "todo-001") (After.Todo "Review λ" True)]) [])
      assert (oldId /= targetId)
      assert (observations ==
        [ StepObservation (Rationale "Rename" []) (RecordedRoot oldId (wrap expectedOld)) (RecordedRoot oldId (wrap expectedRenamed))
        , StepObservation (Rationale "Add completion status" []) (RecordedRoot oldId (wrap expectedRenamed)) (RecordedRoot targetId (wrap expectedAfter))
        , StepObservation (Rationale "Complete the review" []) (RecordedRoot targetId (wrap expectedAfter)) (RecordedRoot targetId (wrap expectedFinal))
        ])
      encoded <- either fail pure (encodeEvolutionReply (knowledgeBaseCodec AfterCodec.rootCodec) (Right (EvolutionOutput value observations)))
      putStrLn encoded
    _ -> fail "Expected a pure successful evolution entry"
  putStrLn "Generated evolution bindings preserve typed schema and metadata transitions."
  refusal <- either fail pure (encodeEvolutionReply AfterCodec.rootCodec
    (Left (EvolutionFailure [Diagnostic Error "evolution.refused" "Cannot reconcile λ"
      (Just (FactLocation "todos" "todo-001" (Just "title")))])))
  putStrLn refusal

assert :: Bool -> IO ()
assert True = pure ()
assert False = fail "Generated binding observation mismatch"

wrap value = record [("facts",value),("recipes",either error id (parseValue "[]"))]
