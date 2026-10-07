-- Pure recipe/fact state focusing and common evolution observation/failure laws.
-- Reused by the real GHC/MicroHs proof; no persistence or generated workspace API.
{-# LANGUAGE OverloadedStrings #-}
module RecipeEditTests (main) where

import Kyyn.Evolution
import Kyyn.Recipe (RecipeEdit, RecipeEvolution, editFacts, getRecipeState,
  putRecipeState, modifyRecipeState)
import Kyyn.Edit.Internal (Collection(..), execStateT)
import qualified Kyyn.Evolution.Internal as Internal
import Kyyn.Types.Diagnostic (errorDiagnostic)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Text.JSON.Types (JSValue(..), toJSString)

data Root = Root [Fact String] deriving (Eq, Show)
data ReviewState = ReviewState [String] deriving (Eq, Show)

todos :: Collection Root String
todos = Collection "todos" (lens (\(Root values) -> values) (\_ -> Root))

main :: IO ()
main = do
  let before = Root [Fact (FactId "one") "Draft"]
      state = ReviewState ["email-1"]
      action :: RecipeEdit Root ReviewState ()
      action = do
        ReviewState seen <- getRecipeState
        editFacts $ within todos $ update (FactId "one") (put "Ready")
        putRecipeState (ReviewState (seen ++ ["email-2"]))
        modifyRecipeState (\(ReviewState ids) -> ReviewState (ids ++ ["email-3"]))
      after = Root [Fact (FactId "one") "Ready"]
      next = ReviewState ["email-1", "email-2", "email-3"]
      pair = (before, state)
  assert "fact and recipe edits compose" (execStateT action pair == Right (after, next))
  assert "state read preserves both values" (execStateT getRecipeState pair == Right pair)
  assert "state-only edit preserves facts"
    (execStateT (putRecipeState next) pair == Right (before, next))
  assert "fact-only edit preserves state"
    (execStateT (editFacts (put after)) pair == Right (after, state))
  assert "stateless recipe uses unit"
    (execStateT (editFacts (put after) >> putRecipeState ()) (before, ()) == Right (after, ()))
  assert "focused edit returns its result" $
    execStateT (do
      old <- editFacts get
      editFacts (put after)
      editFacts (put old)) pair == Right pair
  let refusal = [errorDiagnostic "recipe.test-refused" "Refused"]
      failure = EvolutionFailure refusal
  assert "fact refusal discards earlier state edit" $
    execStateT (putRecipeState next >> editFacts (refuse refusal)) pair == Left failure
  assert "state refusal discards earlier fact edit" $
    execStateT (editFacts (put after) >> refuse refusal) pair == Left failure
  let binding = Internal.RootBinding "recipe-pair" (JSString . toJSString . show)
      reason = Rationale "Review email" []
      step :: RecipeEvolution Root ReviewState
      step = Internal.edit binding reason action
      stateStep = Internal.edit binding (Rationale "Remember another email" [])
        (putRecipeState state)
      stop = Internal.edit binding reason (editFacts (refuse refusal))
      encode value = Internal.RecordedRoot "recipe-pair" (JSString (toJSString (show value)))
  assert "one shared observation includes root and state" $
    Internal.evaluateEvolution step pair == Right
      (Internal.EvolutionOutput (after, next)
        [Internal.StepObservation reason (encode pair) (encode (after, next))])
  assert "recipe evolution uses ordinary composition and identity" $
    Internal.evaluateEvolution (step >=> stateStep >=> identityEvolution) pair ==
      Internal.evaluateEvolution (identityEvolution >=> step >=> stateStep) pair
  assert "failed composed step returns no partial facts/state/report" $
    Internal.evaluateEvolution (step >=> stop) pair == Left failure
  putStrLn "Recipe state focusing and shared evolution semantics passed."

assert :: String -> Bool -> IO ()
assert _ True = pure ()
assert label False = fail label
