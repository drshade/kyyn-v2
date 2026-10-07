{-# LANGUAGE DataKinds, GADTs #-}
module RecipeTests (recipeTests) where

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Effectful (Eff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Recipe (RecipeDefinition(..), RecipeId(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Git (Repository(..), GitRevision, TreePath(..), gitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (directoryScope, relativePath, relativeName)
import Kyyn.Plumbing.Capability.Git (Git(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Porcelain.Capability.Recipe (findRecipeAt)
import Kyyn.Porcelain.Capability.RecipeStore
import Kyyn.Porcelain.Capability.RootStore (RootStore)
import Kyyn.Porcelain.Interpreter.RecipeStore (runRecipeStore)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)

recipeTests :: IO ()
recipeTests = do
  let recipe = Fact (FactId "syncTodos") (OpenRecipe "Read current documents, then explain the proposed changes." "()")
      check label condition = unless condition (fail label)
      kb = KnowledgeBase repository (Subtree (either error id (relativePath "nested/kb")))
      at = either error id (gitRevision (replicate 40 'a'))
      current = either error id (gitRevision (replicate 40 'b'))
      run :: Eff '[RecipeStore,RootStore,DhallHandling,Git] a -> a
      run = runPureEff . recording at . runDhallHandling . runRootStore . runRecipeStore
  check "Selected revision's recipes not returned" (run (loadRecipesAt kb at) == Right [recipe])
  check "Recipe instructions lost" (run (findRecipeAt kb at (RecipeId "syncTodos")) == Right recipe)
  check "Empty recipe list became an error" (run (loadRecipesAt kb current) == Right [])
  check "Unknown recipe accepted" (case run (findRecipeAt kb at (RecipeId "missing")) of
    Left [Diagnostic _ "recipe.unknown" _ _] -> True
    _ -> False)
  putStrLn "Recipe discovery reads only selected Git recipe definitions without a compiler."

repository :: Repository
repository = Repository (either error id (directoryScope "/fixture"))

recording :: GitRevision -> Eff (Git : es) a -> Eff es a
recording selected = interpret $ \_ request -> case request of
  ReadFileAt actual revision path | actual == repository -> case relativeName path of
    "nested/kb/root/recipes.dhall" -> pure (Right (if revision == selected then Just recipeData else Nothing))
    _ -> error "Recipe store read outside selected KB/revision"
  _ -> error "Recipe discovery performed a non-document Git operation"

recipeData :: ByteString
recipeData = "let Recipe = < OpenAgent : { instructions : Text, stateType : Text } | ClosedAgent : { flow : Text } > in [{ id = \"syncTodos\", value = Recipe.OpenAgent { instructions = \"Read current documents, then explain the proposed changes.\", stateType = \"()\" } }]"
