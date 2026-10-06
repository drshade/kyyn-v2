module KnowledgeBaseTests (main) where

import Kyyn.Evolution
import qualified Kyyn.Edit.Internal as Internal
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.Diagnostic (errorDiagnostic)

main :: IO ()
main = do
  let ident = FactId "syncTodos"
      task = Fact ident (OpenAgent "Read the pending evidence")
      initial = KnowledgeBase (7 :: Integer) []
      withTask = KnowledgeBase 7 [task]
      edited = KnowledgeBase 8 [Fact ident (OpenAgent "Explain each change")]
      appendTask = within recipes (append task)
      updateTask = do
        within recipes $ update ident $ put (OpenAgent "Explain each change")
        modifying facts (+ 1)
  assert "append recipe preserves domain facts" (execute appendTask initial == Right withTask)
  assert "recipe/domain edits share one state action" (execute updateTask withTask == Right edited)
  assert "current recipe leaves state unchanged" (execute (within recipes $ current ident) withTask == Right withTask)
  assert "remove recipe preserves domain facts" (execute (within recipes $ remove ident) withTask == Right initial)
  assert "duplicate recipe ID refuses" (isFailure (execute appendTask withTask))
  assert "missing recipe refuses" (isFailure (execute (within recipes $ remove ident) initial))
  assert "ambiguous recipe refuses" (isFailure
    (execute (within recipes $ update ident (put (OpenAgent "changed"))) (KnowledgeBase (7 :: Integer) [task,task])))
  assert "type-changing facts lens preserves recipes"
    (set facts ("seven" :: String) withTask == KnowledgeBase "seven" [task])
  assert "onFacts preserves recipes during schema change"
    (onFacts (Right . show) withTask == Right (KnowledgeBase "7" [task]))
  let failure = EvolutionFailure [errorDiagnostic "test.refused" "No change"]
  assert "onFacts preserves failure" (onFacts (\_ -> Left failure) withTask ==
    (Left failure :: Either EvolutionFailure (KnowledgeBase String)))
  assert "refusal discards recipe and domain changes" (execute
    (do appendTask; modifying facts (+ 1); refuse [errorDiagnostic "test.refused" "No change"])
    initial == Left failure)
  let domain = Internal.Collection "recipes" (facts . lens id (\_ next -> next))
      sameName = KnowledgeBase [Fact ident ("domain value" :: String)] [task]
  assert "domain collection and recipe names stay independent" (execute
    (within domain $ update ident $ put "updated domain value") sameName ==
    Right (KnowledgeBase [Fact ident "updated domain value"] [task]))
  putStrLn "Knowledge-base recipe edits, domain focus, schema lifting and refusals passed."

execute :: Edit a r -> a -> Either EvolutionFailure a
execute = Internal.execStateT

isFailure :: Either a b -> Bool
isFailure (Left _) = True
isFailure (Right _) = False

assert :: String -> Bool -> IO ()
assert _ True = pure ()
assert label False = fail label
