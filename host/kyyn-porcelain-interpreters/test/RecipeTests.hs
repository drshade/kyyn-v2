{-# LANGUAGE DataKinds, GADTs #-}
module RecipeTests (recipeTests) where

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Effectful (Eff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Curation
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
  let recipe = Fact (FactId "syncTodos") (Recipe "Read current documents, then explain the proposed changes.")
      check label condition = unless condition (fail label)
      kb = KnowledgeBase repository (Subtree (either error id (relativePath "nested/kb")))
      at = either error id (gitRevision (replicate 40 'a'))
      current = either error id (gitRevision (replicate 40 'b'))
      run :: Maybe ByteString -> Eff '[RecipeStore,RootStore,DhallHandling,Git] a -> a
      run progress = runPureEff . recording at progress . runDhallHandling . runRootStore . runRecipeStore
  check "Selected revision's recipes not returned" (run Nothing (loadRecipesAt kb at) == Right [recipe])
  check "Recipe instructions lost" (run Nothing (findRecipeAt kb at (RecipeId "syncTodos")) == Right recipe)
  check "Empty recipe list became an error" (run Nothing (loadRecipesAt kb current) == Right [])
  check "Missing register not empty" (run Nothing (loadCurationAt kb at) == Right emptyCurationRegister)
  check "Listing instructions tried to read corrupt progress"
    (run (Just "malformed") (loadRecipesAt kb at) == Right [recipe])
  check "Unknown recipe accepted" (case run Nothing (findRecipeAt kb at (RecipeId "missing")) of
    Left [Diagnostic _ "curation.recipe-unknown" _ _] -> True
    _ -> False)
  check "Malformed register accepted" (case run (Just "malformed") (loadCurationAt kb at) of Left _ -> True; _ -> False)
  putStrLn "Recipe discovery reads only selected Git recipe/register documents without a compiler."

repository :: Repository
repository = Repository (either error id (directoryScope "/fixture"))

recording :: GitRevision -> Maybe ByteString -> Eff (Git : es) a -> Eff es a
recording selected progress = interpret $ \_ request -> case request of
  ReadFileAt actual revision path | actual == repository -> case relativeName path of
    "nested/kb/root/recipes.dhall" -> pure (Right (if revision == selected then Just recipeData else Nothing))
    "nested/kb/root/curation.dhall" | revision == selected -> pure (Right progress)
    _ -> error "Recipe store read outside selected KB/revision"
  _ -> error "Recipe discovery performed a non-document Git operation"

recipeData :: ByteString
recipeData = "[{ id = \"syncTodos\", value = { instructions = \"Read current documents, then explain the proposed changes.\" } }]"
