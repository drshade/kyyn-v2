module Kyyn.Porcelain.Capability.Recipe (findRecipeAt, proposeFromRecipe) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Curation (RecipeId(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (Recipe(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Git (GitRevision, TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Root (Root(..))
import Kyyn.Domain.Recipe (RecipeDefinition, StoredRecipe(..))
import Kyyn.Domain.Evolution (EvolutionName(..), EvolutionWorkspace)
import Kyyn.Porcelain.Capability.RecipeExecution (RecipeExecution, executeRecipeFlow)
import Kyyn.Porcelain.Capability.EvolutionAuthoring (EvolutionAuthoring, createFactProposal)
import Kyyn.Porcelain.Capability.RootStore (rootLocation)
import Kyyn.Porcelain.Capability.RecipeStore (RecipeStore, loadRecipesAt)
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadRootAt)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation, preparePlugins)

findRecipeAt :: RecipeStore :> es => KnowledgeBase -> GitRevision -> RecipeId
  -> Eff es (Either [Diagnostic] (Fact RecipeDefinition))
findRecipeAt kb revision (RecipeId name) = runExceptT $ do
  recipes <- ExceptT (loadRecipesAt kb revision)
  case [recipe | recipe@(Fact (FactId identity) _) <- recipes, identity == name] of
    [recipe] -> pure recipe
    _ -> throwE [errorDiagnostic "recipe.unknown" ("No recipe named " ++ Text.unpack name ++ " is declared in the selected root")]

proposeFromRecipe :: (RootOpening :> es, PluginPreparation :> es,
  RecipeExecution :> es, EvolutionAuthoring :> es)
  => KnowledgeBase -> GitRevision -> RecipeId -> Maybe Text.Text
  -> Eff es (Either [Diagnostic] EvolutionWorkspace)
proposeFromRecipe kb@(KnowledgeBase repository _) revision recipe@(RecipeId name) request = runExceptT $ do
  location <- either (failure "kb.path") pure (rootLocation kb)
  root@(Root _ _ code _ recipes) <- ExceptT (loadRootAt repository revision (Subtree location))
  (entry,state) <- case [value | Fact (FactId actual) value <- recipes, actual == name] of
    [StoredRecipe (ClosedAgent value) _ _ state] -> pure (value,state)
    [StoredRecipe (OpenAgent _) _ _ _] -> failure "recipe.open-agent" "This recipe has instructions for an external agent, not an executable flow"
    _ -> failure "recipe.unknown" ("No recipe named " ++ Text.unpack name)
  plugins <- ExceptT (preparePlugins code)
  proposal <- ExceptT (executeRecipeFlow root plugins entry state request)
  ExceptT (createFactProposal kb (EvolutionName ("run " ++ Text.unpack name)) revision recipe proposal)
  where failure code message = throwE [errorDiagnostic code message]
