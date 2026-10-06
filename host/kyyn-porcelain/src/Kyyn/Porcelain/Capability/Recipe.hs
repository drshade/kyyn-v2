module Kyyn.Porcelain.Capability.Recipe (findRecipeAt, pendingRecipeEvidence, proposeFromRecipe) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Control.Monad (unless, forM)
import Data.Coerce (coerce)
import Data.List (nub)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Curation
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Git (GitRevision, TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Root (Root(..))
import Kyyn.Domain.Contract (contractId)
import Kyyn.Domain.Evolution (EvolutionName(..), EvolutionWorkspace)
import Kyyn.Domain.FactProposal (FactProposal(..))
import qualified Kyyn.Types.Curation as Declaration
import Kyyn.Porcelain.Capability.RecipeExecution (RecipeExecution, executeRecipeFlow)
import Kyyn.Porcelain.Capability.EvolutionAuthoring (EvolutionAuthoring, createFactProposal)
import Kyyn.Porcelain.Capability.PluginRead (PluginRead, loadCapturedInput)
import Kyyn.Porcelain.Capability.RootStore (rootLocation)
import Kyyn.Domain.Plugin (PluginName, ConnectorName(..), pluginNameText)
import Kyyn.Porcelain.Capability.RecipeStore
import Kyyn.Porcelain.Capability.Connector (selectConnectorEvidence)
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore, loadCurrentEvidence)
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore)
import Kyyn.Porcelain.Capability.RootOpening (RootOpening, loadRootAt)
import Kyyn.Porcelain.Capability.PluginPreparation

findRecipeAt :: RecipeStore :> es => KnowledgeBase -> GitRevision -> RecipeId
  -> Eff es (Either [Diagnostic] (Fact Recipe))
findRecipeAt kb revision (RecipeId name) = runExceptT $ do
  recipes <- ExceptT (loadRecipesAt kb revision)
  case [recipe | recipe@(Fact (FactId identity) _) <- recipes, identity == name] of
    [recipe] -> pure recipe
    _ -> throwE [errorDiagnostic "curation.recipe-unknown" ("No recipe named " ++ Text.unpack name ++ " is declared in the selected root")]

proposeFromRecipe :: (RootOpening :> es, PluginPreparation :> es, PluginRead :> es,
  RecipeExecution :> es, EvolutionAuthoring :> es)
  => KnowledgeBase -> GitRevision -> RecipeId -> [(PluginName,ConnectorName)]
  -> Eff es (Either [Diagnostic] EvolutionWorkspace)
proposeFromRecipe kb@(KnowledgeBase repository _) revision recipe@(RecipeId name) selected = runExceptT $ do
  unless (not (null selected)) (failure "recipe.inputs" "Select at least one PLUGIN INSTANCE pair")
  unless (length selected == length (nub selected)) (failure "recipe.duplicate-input" "Each PLUGIN INSTANCE pair must appear only once")
  location <- either (failure "kb.path") pure (rootLocation kb)
  root@(Root _ _ code progress recipes) <- ExceptT (loadRootAt repository revision (Subtree location))
  entry <- case [value | Fact (FactId actual) value <- recipes, actual == name] of
    [ClosedAgent value] -> pure value
    [OpenAgent _] -> failure "recipe.open-agent" "This recipe has instructions for an external agent, not an executable flow"
    _ -> failure "curation.recipe-unknown" ("No recipe named " ++ Text.unpack name)
  plugins <- ExceptT (preparePlugins code)
  captured <- forM selected $ \(plugin,instanceName) -> do
    (PreparedPackage _ identity _,ConfiguredConnector _ _ (PreparedConnector {payloadContract = payload}) _) <-
      ExceptT (pure (selectedInstance plugin instanceName plugins))
    current <- ExceptT (loadCapturedInput (ConnectorInstanceRef plugin (coerce instanceName))
      (EvidenceProducer identity (contractId payload)) payload)
    pending <- either (failure "recipe.pending" . show) pure (pendingEvidence recipe progress (captureEvidence current))
    pure (pending,current)
  proposal@(FactProposal _ declaration) <- ExceptT (executeRecipeFlow root plugins entry recipe captured)
  ExceptT (pure (checkRecipeCuration recipe (map fst captured) declaration))
  ExceptT (createFactProposal kb (EvolutionName ("curate " ++ Text.unpack name)) revision proposal)
  where failure code message = throwE [errorDiagnostic code message]

checkRecipeCuration :: RecipeId -> [PendingEvidence] -> Declaration.Curation -> Either [Diagnostic] ()
checkRecipeCuration recipe inputs (Declaration.Curation declared handled) = do
  unless (recipe == declared) (failure "recipe.curation-mismatch" "The proposal must name the invoked recipe")
  mapM_ check handled
  where
    failure code message = Left [errorDiagnostic code message]
    available = map input inputs
    input batch = case batch of
      PendingEvidence snapshot changes -> (scopeOf snapshot, Just (map fst changes))
      Reconciliation snapshot _ -> (scopeOf snapshot, Nothing)
    scopeOf (EvidenceSnapshotRef (ConnectorInstanceRef plugin instanceName) _ (FetchId fetch)) =
      Declaration.EvidenceScope (Text.pack (pluginNameText plugin)) (Text.pack instanceName) (Text.pack fetch)
    check item = do
      let scope = case item of Declaration.EntireBatch value -> value; Declaration.IndividualRecords value _ -> value
      ids <- maybe (failure "recipe.curation-scope" "The proposal acknowledges a scope not supplied to this invocation") Right (lookup scope available)
      case item of
        Declaration.EntireBatch _ -> Right ()
        Declaration.IndividualRecords _ chosen -> case ids of
          Nothing -> failure "curation.producer-changed" "The evidence producer changed; acknowledge the entire reconciliation batch or leave it pending"
          Just pending -> unless (all (`elem` pending) chosen)
            (failure "recipe.curation-record" "The proposal acknowledges IDs outside the supplied pending batch")

pendingRecipeEvidence
  :: (RecipeStore :> es, RootOpening :> es, EvolutionStore :> es, PluginPreparation :> es, EvidenceStore :> es)
  => KnowledgeBase -> GitRevision -> RecipeId -> PluginName -> ConnectorName
  -> Eff es (Either [Diagnostic] PendingEvidence)
pendingRecipeEvidence kb revision recipe plugin instanceName = runExceptT $ do
  _ <- ExceptT (findRecipeAt kb revision recipe)
  progress <- ExceptT (loadCurationAt kb revision)
  (instanceRef,producer,payload) <- ExceptT (selectConnectorEvidence kb revision plugin instanceName)
  current <- ExceptT $ fmap (either (Left . pure . evidenceProblemDiagnostic) Right)
    (loadCurrentEvidence instanceRef producer payload)
  captured <- maybe (throwE [evidenceProblemDiagnostic NotFetched]) pure current
  either (throwE . pure . problem) pure (pendingEvidence recipe progress (captureEvidence captured))
  where
    problem CurationProducerChanged = errorDiagnostic "curation.producer-changed"
      "This recipe last handled a different evidence producer; inspect current evidence and acknowledge an entire batch to reconcile it"
    problem (InvalidCurationCapture message) = errorDiagnostic "curation.progress" message
