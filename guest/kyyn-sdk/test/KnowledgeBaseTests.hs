{-# LANGUAGE OverloadedStrings #-}
module KnowledgeBaseTests (main) where

import Kyyn.Evolution
import qualified Kyyn.Edit.Internal as Internal
import Kyyn.Recipe.Internal (KnowledgeBase(..), RecipeType(..), StoredRecipe(..), storeRecipe)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.Diagnostic (errorDiagnostic)
import Text.JSON.Types (JSValue(..), toJSString, fromJSString)

main :: IO ()
main = do
  let ident = RecipeId "syncTodos"
      key = FactId "syncTodos"
      definition = openRecipe unitRecipeType "Review relevant evidence"
      changedDefinition = openRecipe unitRecipeType "Explain each change"
      task = Fact key (storeRecipe definition ())
      initial = KnowledgeBase (7 :: Integer) []
      withTask = KnowledgeBase 7 [task]
      edited = KnowledgeBase 8 [Fact key (storeRecipe changedDefinition ())]
      appendTask = createRecipe ident definition ()
      updateTask = do
        updateRecipe unitRecipeType ident changedDefinition Right
        modifying facts (+ 1)
  assert "append recipe preserves domain facts" (execute appendTask initial == Right withTask)
  assert "recipe/domain edits share one state action" (execute updateTask withTask == Right edited)
  assert "remove recipe preserves domain facts" (execute (removeRecipe ident) withTask == Right initial)
  assert "duplicate recipe ID refuses" (isFailure (execute appendTask withTask))
  assert "missing recipe refuses" (isFailure (execute (removeRecipe ident) initial))
  assert "updating missing recipe refuses" (isFailure (execute updateTask initial))
  assert "ambiguous recipe refuses" (isFailure
    (execute updateTask (KnowledgeBase (7 :: Integer) [task,task])))
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
      sameName = KnowledgeBase [Fact key ("domain value" :: String)] [task]
  assert "domain collection and recipe names stay independent" (execute
    (within domain $ update key $ put "updated domain value") sameName ==
    Right (KnowledgeBase [Fact key "updated domain value"] [task]))
  let second = RecipeId "otherTask"
      boolDefinition = openRecipe boolType "Remember a flag"
      stringDefinition = openRecipe stringType "Remember a note"
      firstValue = Fact key (storeRecipe boolDefinition False)
      secondValue = Fact (FactId "otherTask") (storeRecipe boolDefinition True)
      both = KnowledgeBase (7 :: Integer) [firstValue, secondValue]
  assert "different recipes sharing one type have separate values" (execute
    (updateRecipe boolType ident boolDefinition (Right . not)) both ==
    Right (KnowledgeBase 7 [Fact key (storeRecipe boolDefinition True),secondValue]))
  assert "state type migration preserves other recipes" (execute
    (updateRecipe boolType ident stringDefinition (Right . show)) both ==
    Right (KnowledgeBase 7 [Fact key (storeRecipe stringDefinition "False"),secondValue]))
  assert "unit state can migrate to an authored state" (execute
    (updateRecipe unitRecipeType ident boolDefinition (\() -> Right True)) withTask ==
    Right (KnowledgeBase 7 [Fact key (storeRecipe boolDefinition True)]))
  assert "same shape under a different type cannot decode selected state" (isFailure (execute
    (updateRecipe (renamedType boolType) ident boolDefinition Right) both))
  assert "changed contract with the same name refuses before decoding" (isFailure (execute
    (updateRecipe (changedContract boolType) ident boolDefinition Right) both))
  assert "failed migration returns no partial root" (execute
    (do modifying facts (+ 1); updateRecipe boolType ident stringDefinition (const (Left failure))) both == Left failure)
  assert "remove and recreate require the new initial value" (execute
    (do removeRecipe ident; createRecipe ident stringDefinition "Fresh") both ==
    Right (KnowledgeBase 7 [secondValue,Fact key (storeRecipe stringDefinition "Fresh")]))
  let malformed = case secondValue of
        Fact name (StoredRecipe method typeName fingerprint _) ->
          Fact name (StoredRecipe method typeName fingerprint (JSArray []))
      withMalformed = KnowledgeBase (7 :: Integer) [firstValue, malformed]
  assert "editing a recipe does not decode another recipe's state" (execute
    (updateRecipe boolType ident boolDefinition Right) withMalformed == Right withMalformed)
  assert "selected malformed state returns a diagnostic" (isFailure (execute
    (updateRecipe boolType second boolDefinition Right) withMalformed))
  putStrLn "Typed recipe creation, migration, isolation, removal and atomic refusal passed."

boolType :: RecipeType Bool
boolType = RecipeType "Flags.State" "flags-contract" JSBool decode
  where
    decode (JSBool value) = Right value
    decode _ = Left "Expected Bool"

stringType :: RecipeType String
stringType = RecipeType "Notes.State" "notes-contract" (JSString . toJSString) decode
  where
    decode (JSString value) = Right (fromJSString value)
    decode _ = Left "Expected String"

renamedType :: RecipeType state -> RecipeType state
renamedType (RecipeType _ identity encode decode) = RecipeType "Other.State" identity encode decode

changedContract :: RecipeType state -> RecipeType state
changedContract (RecipeType name _ encode _) = RecipeType name "changed-contract" encode
  (\_ -> error "A mismatched contract must not reach the decoder")

execute :: Edit a r -> a -> Either EvolutionFailure a
execute = Internal.execStateT

isFailure :: Either a b -> Bool
isFailure (Left _) = True
isFailure (Right _) = False

assert :: String -> Bool -> IO ()
assert _ True = pure ()
assert label False = fail label
