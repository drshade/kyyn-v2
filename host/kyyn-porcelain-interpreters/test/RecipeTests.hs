{-# LANGUAGE DataKinds, GADTs #-}
module RecipeTests (recipeTests) where

import Kyyn.Types.KnowledgeBase (Lifetime(..), InteractionBindings(..), ChildReference(..), EventReference(EventReference), FlowEntryRef(..))
import Kyyn.Domain.FlowClosure (FlowDeclaration(..), flowClosure)
import Control.Monad (unless)
import qualified Data.Text as Text
import Data.ByteString (ByteString)
import Effectful (Eff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Recipe (RecipeDefinition(..), RecipeId(..), checkRecipeDefinitions)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Git (Repository(..), GitRevision, TreePath(..), gitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (directoryScope, relativePath, relativeName)
import Kyyn.Plumbing.Capability.Git (Git(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Porcelain.Capability.Recipe (findRecipeAt)
import Kyyn.Porcelain.Protocol.RecipePersistence (decodeRecipes)
import Kyyn.Porcelain.Capability.RecipeStore
import Kyyn.Porcelain.Capability.RootStore (RootStore)
import Kyyn.Porcelain.Interpreter.RecipeStore (runRecipeStore)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)

recipeTests :: IO ()
recipeTests = do
  let recipe = Fact (FactId "syncTodos") (OpenRecipe Ordinary "Read current documents, then explain the proposed changes." "()")
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
  let old = "let Recipe = < OpenAgent : { instructions : Text, stateType : Text } | ClosedAgent : { flow : Text } > in [{ id = \"old\", value = Recipe.ClosedAgent { flow = \"Flows.old\" } }]"
  check "Missing lifetime error lacks path and field" (case run (decodeRecipes (Just old)) of
    Left diagnostics -> let rendered = Text.pack (show diagnostics)
                        in "recipes.dhall" `Text.isInfixOf` rendered && "lifetime" `Text.isInfixOf` rendered
    Right _ -> False)
  let child = Fact (FactId "child") (ClosedRecipe (Interactive (InteractionBindings [] [])) (FlowEntryRef "Flows.child"))
      parent = Fact (FactId "parent") (ClosedRecipe
        (Interactive (InteractionBindings [ChildReference (RecipeId "child") (FlowEntryRef "Flows.child")] [])) (FlowEntryRef "Flows.parent"))
      refused definitions = case checkRecipeDefinitions definitions of
        Left diagnostics -> let rendered = Text.pack (show diagnostics)
                            in "parent" `Text.isInfixOf` rendered && "child" `Text.isInfixOf` rendered
        Right _ -> False
  check "Parent and child added together refused" (checkRecipeDefinitions [parent,child] == Right [parent,child])
  let duplicateParent = Fact (FactId "parent") (ClosedRecipe
        (Interactive (InteractionBindings (replicate 2 (ChildReference (RecipeId "child") (FlowEntryRef "Flows.child"))) [])) (FlowEntryRef "Flows.parent"))
      self = Fact (FactId "self") (ClosedRecipe
        (Interactive (InteractionBindings [ChildReference (RecipeId "self") (FlowEntryRef "Flows.self")] [])) (FlowEntryRef "Flows.self"))
  check "Duplicate child accepted" (case checkRecipeDefinitions [duplicateParent,child] of Left _ -> True; Right _ -> False)
  let eventRef = EventReference "fixture" "Updates" "updates" "question"
      duplicateEvents = Fact (FactId "events") (ClosedRecipe (Interactive (InteractionBindings [] [eventRef,eventRef])) (FlowEntryRef "Flows.events"))
  check "Duplicate event declarations accepted" (case checkRecipeDefinitions [duplicateEvents] of
    Left diagnostics -> "duplicate event declarations" `Text.isInfixOf` Text.pack (show diagnostics)
    Right _ -> False)
  check "Self reference refused" (checkRecipeDefinitions [self] == Right [self])
  check "Missing child accepted" (refused [parent])
  check "Noninteractive child accepted" (refused [parent,Fact (FactId "child") (ClosedRecipe Ordinary (FlowEntryRef "Flows.child"))])
  check "Retargeted child accepted" (refused [parent,Fact (FactId "child") (ClosedRecipe (Interactive (InteractionBindings [] [])) (FlowEntryRef "Flows.other"))])
  let flow name refs = Fact (FactId name) (ClosedRecipe (Interactive (InteractionBindings
        [ChildReference (RecipeId childName) (FlowEntryRef "Flows.shared") | childName <- refs] [])) (FlowEntryRef "Flows.shared"))
      graph = [flow "root" ["left","right"], flow "left" ["leaf"], flow "right" ["leaf"], flow "leaf" ["root"], flow "unused" []]
  check "Closure must handle diamond/cycle and preserve IDs sharing source" (case flowClosure graph (RecipeId "root") of
    Right declarations -> [ident | FlowDeclaration ident _ _ <- declarations] == map RecipeId ["root","left","leaf","right"]
    Left _ -> False)
  check "Ordinary flow must not start interactively" (case flowClosure [recipe] (RecipeId "syncTodos") of Left _ -> True; Right _ -> False)
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
recipeData = "let Recipe = < OpenAgent : { lifetime : < Ordinary | Interactive : { children : List { recipe : Text, flow : Text }, events : List { plugin : Text, connector : Text, instance : Text, event : Text } } >, instructions : Text, stateType : Text } | ClosedAgent : { lifetime : < Ordinary | Interactive : { children : List { recipe : Text, flow : Text }, events : List { plugin : Text, connector : Text, instance : Text, event : Text } } >, flow : Text } > in [{ id = \"syncTodos\", value = Recipe.OpenAgent { lifetime = < Ordinary | Interactive : { children : List { recipe : Text, flow : Text }, events : List { plugin : Text, connector : Text, instance : Text, event : Text } } >.Ordinary, instructions = \"Read current documents, then explain the proposed changes.\", stateType = \"()\" } }]"
