module Kyyn.Porcelain.Capability.Curation (resolveCuration) where

import Control.Monad (foldM, unless)
import qualified Data.Text as Text
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Effectful (Eff, (:>))
import Kyyn.Domain.Curation
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence
import Kyyn.Domain.Plugin (pluginName)
import qualified Kyyn.Types.Curation as Declaration
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore, resolveEvidenceCapture)

resolveCuration :: EvidenceStore :> es => [Fact recipe] -> Maybe Declaration.Curation
  -> CurationRegister -> Eff es (Either [Diagnostic] CurationRegister)
resolveCuration _ Nothing register = pure (Right register)
resolveCuration recipes (Just (Declaration.Curation recipe@(RecipeId name) handled)) register = runExceptT $ do
  _ <- either (reject "curation.recipe-invalid") pure (recipeId (Text.unpack name))
  unless (name `elem` [identity | Fact (FactId identity) _ <- recipes])
    (reject "curation.recipe-unknown" ("No recipe named " ++ Text.unpack name ++ " exists in the returned knowledge base"))
  foldM apply register handled
  where
    apply progress declaration = do
      let (Declaration.EvidenceScope plugin instanceName fetch, selection) = case declaration of
            Declaration.EntireBatch scope -> (scope, EntireBatch)
            Declaration.IndividualRecords scope ids -> (scope, IndividualRecords ids)
      selected <- either (reject "curation.scope-invalid") pure (pluginName (Text.unpack plugin))
      unless (not (Text.null instanceName || Text.null fetch))
        (reject "curation.scope-invalid" "Evidence scope requires an instance and fetch")
      case selection of
        IndividualRecords ids -> unless (all (\(EvidenceId item) -> not (Text.null item)) ids)
          (reject "curation.scope-invalid" "Acknowledged evidence IDs must not be empty")
        EntireBatch -> pure ()
      capture <- ExceptT $ fmap (either (Left . pure . scopeProblem) Right)
        (resolveEvidenceCapture (ConnectorInstanceRef selected (Text.unpack instanceName)) (FetchId (Text.unpack fetch)))
      either (reject "curation.progress" . problemMessage) pure (acknowledgeEvidence recipe selection capture progress)
    scopeProblem NotFetched = errorDiagnostic "curation.scope-unavailable"
      "The declared evidence fetch is unavailable; fetch and inspect evidence again, then update the declaration"
    scopeProblem CursorUnavailable = scopeProblem NotFetched
    scopeProblem problem = evidenceProblemDiagnostic problem
    problemMessage CurationProducerChanged =
      "The evidence producer changed; reconcile this instance and acknowledge an entire batch for the recipe"
    problemMessage (InvalidCurationCapture message) = message

reject :: String -> String -> ExceptT [Diagnostic] (Eff es) a
reject code = throwE . pure . errorDiagnostic code
