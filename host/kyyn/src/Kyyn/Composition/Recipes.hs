module Kyyn.Composition.Recipes (dispatchRecipes) where

import Kyyn.Configuration (Host, SelectedKb(..))
import Kyyn.Composition.Runtime
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.KnowledgeBase (knowledgeBaseScope)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Porcelain.Capability.Recipe (findRecipeAt, pendingRecipeEvidence)
import Kyyn.Porcelain.Capability.RecipeStore (loadRecipesAt)
import Kyyn.Porcelain.Interpreter.RecipeStore (runRecipeStore)
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.Recipes
import Kyyn.Surfaces.Result (Response, refusal)

dispatchRecipes :: Host -> Cli.RecipeCommand -> SelectedKb -> IO Response
dispatchRecipes host command (SelectedKb kb revision _) = case command of
  Cli.ListRecipes -> finish $ runBase host . runRecipeStore $
    either refusal recipesResult <$> loadRecipesAt kb revision
  Cli.ShowRecipe recipe -> finish $ runBase host . runRecipeStore $
    either refusal recipeResult <$> findRecipeAt kb revision recipe
  Cli.ListPendingEvidence recipe plugin instanceName -> case knowledgeBaseScope kb of
    Left message -> pure (refusal [errorDiagnostic "kb.path" message])
    Right scope -> withRuntime host $ \toolchain sdk -> finish $
      runRuntime host toolchain . runDocumentPersistenceIO . runEvidenceStore scope
      . runRecipeStore . runRootOpening sdk . runWorkspaceStore . runEvolutionStore . runPluginPreparation sdk $
        either refusal (pendingResult recipe) <$> pendingRecipeEvidence kb revision recipe plugin instanceName
