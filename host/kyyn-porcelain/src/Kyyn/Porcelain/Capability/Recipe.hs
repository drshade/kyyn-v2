module Kyyn.Porcelain.Capability.Recipe (findRecipeAt, pendingRecipeEvidence) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Effectful (Eff, (:>))
import Kyyn.Domain.Curation
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Plugin (PluginName, ConnectorName)
import Kyyn.Porcelain.Capability.RecipeStore
import Kyyn.Porcelain.Capability.Connector (selectConnectorEvidence)
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore, loadCurrentEvidence)
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore)
import Kyyn.Porcelain.Capability.RootOpening (RootOpening)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation)

findRecipeAt :: RecipeStore :> es => KnowledgeBase -> GitRevision -> RecipeId
  -> Eff es (Either [Diagnostic] (Fact Recipe))
findRecipeAt kb revision (RecipeId name) = runExceptT $ do
  recipes <- ExceptT (loadRecipesAt kb revision)
  case [recipe | recipe@(Fact (FactId identity) _) <- recipes, identity == name] of
    [recipe] -> pure recipe
    _ -> throwE [errorDiagnostic "curation.recipe-unknown" ("No recipe named " ++ name ++ " is declared in the selected root")]

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
