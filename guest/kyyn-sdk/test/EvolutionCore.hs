-- Pure SDK evolution/edit composition, observations, recipe changes and failures.
-- No host interpreter, guest compiler or external provider.

{-# LANGUAGE OverloadedStrings #-}
module EvolutionCore (main) where

import Kyyn.Evolution
import Kyyn.Evolution.Internal (RootBinding(..), RecordedRoot(..), StepObservation(..), EvolutionOutput(..), evolve, evaluateEvolution)
import Kyyn.Types.Diagnostic (Diagnostic(..), Severity(..))
import Text.JSON.Types (JSValue(..), toJSString)
import qualified EditTests
import qualified KnowledgeBaseTests
import qualified RecipeTests

main :: IO ()
main = do
  EditTests.main
  KnowledgeBaseTests.main
  RecipeTests.main
  let old = RootBinding "old" (JSString . toJSString . show) :: RootBinding Integer
      new = RootBinding "new" (JSString . toJSString . show) :: RootBinding Integer
      citation = EvidenceRef "sales" "account-one" "org/opportunity/123" ["https://example.test/123"]
      firstReason = Rationale "increment" [citation]
      secondReason = Rationale "undo" []
      thirdReason = Rationale "metadata change" []
      a = evolve old old firstReason (Right . (+1))
      b = evolve old old secondReason (Right . subtract 1)
      c = evolve old new thirdReason Right
      result = evaluateEvolution (a >=> b >=> c) 7
      recorded name value = RecordedRoot name (JSString (toJSString (show (value :: Integer))))
      expected = EvolutionOutput 7
        [ StepObservation firstReason (recorded "old" 7) (recorded "old" 8)
        , StepObservation secondReason (recorded "old" 8) (recorded "old" 7)
        , StepObservation thirdReason (recorded "old" 7) (recorded "new" 7)
        ] Nothing
  assert "ordered observations/cancellation/metadata identity" (result == Right expected)
  assert "associativity" (evaluateEvolution ((a >=> b) >=> c) 7 == evaluateEvolution (a >=> (b >=> c)) 7)
  assert "left identity" (evaluateEvolution (identityEvolution >=> a) 7 == evaluateEvolution a 7)
  assert "right identity" (evaluateEvolution (a >=> identityEvolution) 7 == evaluateEvolution a 7)
  assert "empty identity log" (evaluateEvolution identityEvolution (7 :: Integer) == Right (EvolutionOutput 7 [] Nothing))
  let recipe = RecipeId "syncTodos"
      first = Curation recipe [EntireBatch (EvidenceScope "files" "todos" "f1")]
      second = Curation recipe [IndividualRecords (EvidenceScope "files" "todos" "f2") [EvidenceId "one"]]
      declared = withCuration first identityEvolution >=> withCuration second identityEvolution
      expectedCuration = Curation recipe [EntireBatch (EvidenceScope "files" "todos" "f1"),
        IndividualRecords (EvidenceScope "files" "todos" "f2") [EvidenceId "one"]]
  assert "acknowledgement-only evolution and declaration order"
    (evaluateEvolution declared (7 :: Integer) == Right (EvolutionOutput 7 [] (Just expectedCuration)))
  assert "wrapping appends declarations"
    (evaluateEvolution (withCuration second (withCuration first identityEvolution)) (7 :: Integer)
      == evaluateEvolution declared 7)
  assert "curation composition is associative"
    (evaluateEvolution ((declared >=> a) >=> b) 7 == evaluateEvolution (declared >=> (a >=> b)) 7)
  assert "different recipes refuse" (case evaluateEvolution
    (declared >=> withCuration (Curation (RecipeId "prices") []) identityEvolution) (7 :: Integer) of
      Left (EvolutionFailure [Diagnostic Error "curation.recipe-conflict" _ _]) -> True
      _ -> False)
  let failure = EvolutionFailure [Diagnostic Error "test.refused" "No change" Nothing]
      refused = evolve old old firstReason (\_ -> Left failure)
      unreachable = evolve old new thirdReason (\_ -> error "Executed after failure")
  assert "failure discards the partial result/log and stops composition"
    (evaluateEvolution (a >=> refused >=> unreachable) 7 == Left failure)
  putStrLn "Evolution composition, ordered observations, cancellation and failure checks passed."

assert :: String -> Bool -> IO ()
assert _ True = pure ()
assert label False = fail label
