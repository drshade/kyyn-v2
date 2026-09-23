{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Recipes (recipesResult, recipeResult, pendingResult) where

import Data.Aeson (Value, object, (.=))
import Kyyn.Domain.Curation (Recipe(..), RecipeId(..), PendingEvidence(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Domain.Evidence (EvidenceSnapshotRef(..), ConnectorInstanceRef(..), FetchId(..), EvidenceId(..))
import Kyyn.Domain.Plugin (pluginNameText)
import Kyyn.Surfaces.Result (Response, success)

recipesResult :: [Fact Recipe] -> Response
recipesResult recipes = success (object ["recipes" .= map recipeJson recipes])
  (if null recipes then ["No recipes declared."] else [name | Fact (FactId name) _ <- recipes])

recipeResult :: Fact Recipe -> Response
recipeResult recipe@(Fact (FactId name) (Recipe instructions)) = success (recipeJson recipe) [name,instructions]

recipeJson :: Fact Recipe -> Value
recipeJson (Fact (FactId name) (Recipe instructions)) = object ["name" .= name,"instructions" .= instructions]

pendingResult :: RecipeId -> PendingEvidence -> Response
pendingResult (RecipeId recipe) (PendingEvidence (EvidenceSnapshotRef (ConnectorInstanceRef plugin instanceName) _ (FetchId fetch)) changes) =
  success (object ["recipe" .= recipe,
    "scope" .= object ["plugin" .= pluginNameText plugin,"instance" .= instanceName,"fetch" .= fetch],
    "changes" .= [object ["id" .= item,"kind" .= show kind] | (EvidenceId item,kind) <- changes]])
    (["Recipe: " ++ recipe, "Evidence: " ++ pluginNameText plugin ++ "/" ++ instanceName, "Fetch: " ++ fetch] ++
      if null changes then ["No unacknowledged changes."] else [show kind ++ "  " ++ item | (EvidenceId item,kind) <- changes])
