module Kyyn.Composition.Recipes (dispatchRecipes) where

import Kyyn.Configuration (Host, SelectedKb(..))
import Kyyn.Composition.Runtime
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..), knowledgeBaseScope)
import Kyyn.Domain.Git (Repository(..))
import Kyyn.Domain.Path (scopedPath)
import Kyyn.Porcelain.Capability.EvolutionStore (workspaceLocation)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Porcelain.Capability.Recipe (findRecipeAt, proposeFromRecipe)
import qualified Data.Text as Text
import Kyyn.Plumbing.Interpreter.SecretStore (runSecretStoreIO)
import Kyyn.Plumbing.Interpreter.Judgement (runJudgementIO)
import Kyyn.Plumbing.Interpreter.ModelTurn (runModelTurnIO)
import Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.RecipeExecution (runRecipeExecution)
import Kyyn.Porcelain.Capability.RecipeInspection (describeRecipeAt)
import Kyyn.Porcelain.Interpreter.RecipeInspection (runRecipeInspection)
import Kyyn.Porcelain.Interpreter.EvolutionAuthoring (runEvolutionAuthoring)
import Kyyn.Porcelain.Capability.RecipeStore (loadRecipesAt)
import Kyyn.Porcelain.Interpreter.RecipeStore (runRecipeStore)
import Kyyn.Porcelain.Interpreter.EvidenceStore (runEvidenceStore)
import Kyyn.Plumbing.Interpreter.BlobStorage (runBlobStorageIO)
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
  Cli.DescribeRecipe recipe format -> withRuntime host $ \toolchain sdk -> finish $
    runRuntime host toolchain . runPluginPreparation sdk . runToolPreparation sdk
      . runRootOpening sdk . runRecipeStore . runRecipeInspection $
        either refusal (recipeDescriptionResult revision recipe format) <$> describeRecipeAt kb revision recipe format
  Cli.RunRecipe recipe request -> case knowledgeBaseScope kb of
    Left message -> pure (refusal [errorDiagnostic "kb.path" message])
    Right scope -> withRuntime host $ \toolchain sdk -> finish $
      runRuntime host toolchain . runSecretStoreIO scope . runJudgementIO . runModelTurnIO
      . runDocumentPersistenceIO . (runBlobStorageIO scope . runEvidenceStore scope) . runPluginRead
      . runPluginPreparation sdk . runToolPreparation sdk . runRootOpening sdk . runWorkspaceStore . runEvolutionStore . runRecipeExecution . runEvolutionAuthoring $ do
        result <- proposeFromRecipe kb revision recipe (Text.pack <$> request)
        pure $ case result of
          Left diagnostics -> refusal diagnostics
          Right workspace -> case workspaceLocation workspace of
            Left message -> refusal [errorDiagnostic "kb.path" message]
            Right path -> let KnowledgeBase (Repository repositoryScope) _ = kb
              in recipeRunResult workspace revision (scopedPath repositoryScope path)
