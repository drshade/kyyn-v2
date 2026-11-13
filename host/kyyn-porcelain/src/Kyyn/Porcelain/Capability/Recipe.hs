{-# LANGUAGE OverloadedRecordDot #-}
module Kyyn.Porcelain.Capability.Recipe (findRecipeAt, proposeFromRecipe) where

import Control.Monad (void)
import Control.Monad.Trans.Class (lift)
import Kyyn.Domain.CompiledEntry (entryProgram)
import Kyyn.Domain.CompiledProgram (CompiledProgram(..))
import Kyyn.Domain.RecipeRun (PreparedRecipeRun(..), RecipeRunHeader, RunEventBody(..))
import Kyyn.Porcelain.Capability.RecipeRunStore (RecipeRunStore, RecipeRunWriter(..), withRecipeRun, appendRunEvent)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Recipe (RecipeId(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (Recipe(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Git (GitRevision, TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Root (Root(..))
import Kyyn.Domain.Recipe (RecipeDefinition, StoredRecipe(..))
import Kyyn.Domain.Evolution (EvolutionName(..), EvolutionWorkspace(..))
import Kyyn.Porcelain.Capability.RecipeExecution (RecipeExecution, PreparedRecipe(..), prepareRecipeFlow, executeRecipeFlow)
import Kyyn.Porcelain.Capability.EvolutionAuthoring (EvolutionAuthoring, createFactProposal)
import Kyyn.Porcelain.Capability.RootStore (rootLocation)
import Kyyn.Porcelain.Capability.RecipeStore (RecipeStore, loadRecipesAt)
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadRootAt)

findRecipeAt :: RecipeStore :> es => KnowledgeBase -> GitRevision -> RecipeId
  -> Eff es (Either [Diagnostic] (Fact RecipeDefinition))
findRecipeAt kb revision (RecipeId name) = runExceptT $ do
  recipes <- ExceptT (loadRecipesAt kb revision)
  case [recipe | recipe@(Fact (FactId identity) _) <- recipes, identity == name] of
    [recipe] -> pure recipe
    _ -> throwE [errorDiagnostic "recipe.unknown" ("No recipe named " ++ Text.unpack name ++ " is declared in the selected root")]

proposeFromRecipe :: (RootOpening :> es,
  RecipeRunStore :> es, RecipeExecution :> es, EvolutionAuthoring :> es)
  => KnowledgeBase -> GitRevision -> RecipeId -> Maybe Text.Text
  -> Eff es (Either [Diagnostic] (RecipeRunHeader, EvolutionWorkspace))
proposeFromRecipe kb@(KnowledgeBase repository _) revision recipe@(RecipeId name) request = runExceptT $ do
  location <- either (failure "kb.path") pure (rootLocation kb)
  root@(Root _ _ _ recipes) <- ExceptT (loadRootAt repository revision (Subtree location))
  (entry,state) <- case [value | Fact (FactId actual) value <- recipes, actual == name] of
    [StoredRecipe (ClosedAgent value) _ _ state] -> pure (value,state)
    [StoredRecipe (OpenAgent _) _ _ _] -> failure "recipe.open-agent" "This recipe has instructions for an external agent, not an executable flow"
    _ -> failure "recipe.unknown" ("No recipe named " ++ Text.unpack name)
  prepared <- ExceptT (prepareRecipeFlow root entry state request)
  ExceptT $ withRecipeRun (PreparedRecipeRun kb recipe entry revision (entryProgram prepared.entry).identity prepared.graph prepared.mermaid) $ \writer@(RecipeRunWriter _ header) -> do
    result <- runExceptT $ do
      proposal <- ExceptT (executeRecipeFlow writer prepared)
      workspace@(EvolutionWorkspace _ draft) <- ExceptT (createFactProposal kb (EvolutionName ("run " ++ Text.unpack name)) revision recipe proposal)
      lift (void (appendRunEvent writer (RunCompleted draft)))
      pure (header, workspace)
    case result of
      Left diagnostics -> void (appendRunEvent writer (RunFailed diagnostics))
      Right _ -> pure ()
    pure result
  where failure code message = throwE [errorDiagnostic code message]
