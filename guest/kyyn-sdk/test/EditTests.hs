{-# LANGUAGE RankNTypes, OverloadedStrings #-}
module EditTests (main) where

import Kyyn.Evolution
import qualified Data.Text as Text
import Kyyn.Edit.Internal (Collection(..), execStateT)
import qualified Kyyn.Evolution.Internal as Internal
import Kyyn.Types.Diagnostic (Diagnostic(Diagnostic), Severity(Error), DiagnosticLocation(FactLocation), errorDiagnostic)
import Kyyn.Types.Fact
import Text.JSON.Types (JSValue(..))

data Todo = Todo { title :: String, priority :: Integer } deriving (Eq, Show)
data Root = Root { todos :: [Fact Todo], notes :: [Fact String], label :: String } deriving (Eq, Show)

todoCollection :: Collection Root Todo
todoCollection = Collection "work-items" (lens todos (\r v -> r { todos = v }))

noteCollection :: Collection Root String
noteCollection = Collection "notes" (lens notes (\r v -> r { notes = v }))

priorityLens :: Lens' Todo Integer
priorityLens = lens priority (\t v -> t { priority = v })

main :: IO ()
main = do
  let one = FactId "one"
      two = FactId "two"
      first = Fact one (Todo "Write" 1)
      second = Fact two (Todo "Obsolete" 2)
      input = Root [first,second] [] "September"
      action = do
        within todoCollection $ do
          old <- current one
          n <- update one $ do
            before <- get
            put before { title = title old ++ " report" }
            modifying priorityLens (+ 1)
            gets priority
          append (Fact (FactId "three") (Todo "Review" n))
          remove two
        within noteCollection $ append (Fact one "Ready")
      expected = Root [Fact one (Todo "Write report" 2),Fact (FactId "three") (Todo "Review" 2)] [Fact one "Ready"] "September"
      failure code ident run = assert code $ case execStateT run input of
        Left (EvolutionFailure [Diagnostic Error actual _ loc]) ->
          actual == Text.pack code && loc == Just (FactLocation "work-items" ident Nothing)
        _ -> False
  assert "scoped edits preserve IDs/order/unrelated fields" (execStateT action input == Right expected)
  assert "current is read-only" (execStateT (within todoCollection (current one)) input == Right input)
  failure "edit.fact-missing" "missing" (within todoCollection $ current (FactId "missing"))
  failure "edit.fact-missing" "missing" (within todoCollection $ update (FactId "missing") (error "missing action ran"))
  failure "edit.fact-missing" "missing" (within todoCollection $ remove (FactId "missing"))
  failure "edit.fact-duplicate" "one" (within todoCollection $ append first)
  let duplicate = input { todos = [first,first] }
      ambiguous run = assert "ambiguous ID" $ case execStateT (within todoCollection run) duplicate of
        Left (EvolutionFailure [Diagnostic Error "edit.fact-ambiguous" _ loc]) -> loc == Just (FactLocation "work-items" "one" Nothing)
        _ -> False
  ambiguous (current one)
  ambiguous (remove one)
  ambiguous (update one (error "ambiguous action ran"))
  let refusal = [errorDiagnostic "test.refused" "Not ready"]
  assert "payload refusal discards mutations" $
    execStateT (within todoCollection $ update one $ do
      assigning priorityLens 99
      refuse refusal) input == Left (EvolutionFailure refusal)
  assert "failure discards earlier changes and stops" $
    execStateT (do action; _ <- refuse refusal; error "ran after refusal") input == Left (EvolutionFailure refusal)
  let t = Todo "Test" 3
  assert "get-put" (set priorityLens (view priorityLens t) t == t)
  assert "put-get" (view priorityLens (set priorityLens 7 t) == 7)
  assert "put-put" (set priorityLens 8 (set priorityLens 7 t) == set priorityLens 8 t)
  let nested :: Lens' (Todo,Bool) Todo
      nested = lens fst (\(_,flag) value -> (value,flag))
  assert "zoom and composition" (execStateT (zoom nested (modifying priorityLens (+ 1))) (t,True) ==
    execStateT (modifying (nested . priorityLens) (+ 1)) (t,True))
  assert "type-changing optics" (over pairFirst show ((7 :: Integer),True) == ("7",True))
  let binding = Internal.RootBinding "test" (const JSNull)
      step = Internal.edit binding (Rationale "Prepare review" []) action
      stop = Internal.edit binding (Rationale "Refuse" []) (refuse refusal)
  case Internal.evaluateEvolution step input of
    Right (Internal.EvolutionOutput value observations) ->
      assert "one observation for multiple within blocks" (value == expected && length observations == 1)
    Left err -> fail (show err)
  assert "evolution refusal drops earlier observations" (Internal.evaluateEvolution (step >=> stop) input == Left (EvolutionFailure refusal))
  putStrLn "Fact-aware State edits and composable optics passed."

pairFirst :: Lens (a,c) (b,c) a b
pairFirst = lens fst (\(_,other) value -> (value,other))

assert :: String -> Bool -> IO ()
assert _ True = pure ()
assert message False = fail message
