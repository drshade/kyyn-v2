{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Recipes (recipesResult, recipeResult, pendingResult) where

import Data.Aeson (Value, object, (.=))
import Kyyn.Domain.Curation (Recipe(..), RecipeId(..), PendingEvidence(..))
import Kyyn.Domain.Evidence (EvidenceSnapshotRef(..), ConnectorInstanceRef(..), FetchId(..), EvidenceId(..))
import Kyyn.Domain.Plugin (pluginNameText)
import Kyyn.Surfaces.Result (Response, success)

recipesResult :: [Recipe] -> Response
recipesResult recipes = success (object ["recipes" .= map recipeJson recipes])
  (if null recipes then ["No recipes declared."] else [name | Recipe (RecipeId name) _ <- recipes])

recipeResult :: Recipe -> Response
recipeResult recipe@(Recipe (RecipeId name) instructions) = success (recipeJson recipe) [name,instructions]

recipeJson :: Recipe -> Value
recipeJson (Recipe (RecipeId name) instructions) = object ["name" .= name,"instructions" .= instructions]

pendingResult :: RecipeId -> PendingEvidence -> Response
pendingResult (RecipeId recipe) (PendingEvidence (EvidenceSnapshotRef (ConnectorInstanceRef plugin instanceName) _ (FetchId fetch)) changes) =
  success (object ["recipe" .= recipe,
    "scope" .= object ["plugin" .= pluginNameText plugin,"instance" .= instanceName,"fetch" .= fetch],
    "changes" .= [object ["id" .= item,"kind" .= show kind] | (EvidenceId item,kind) <- changes]])
    (["Recipe: " ++ recipe, "Evidence: " ++ pluginNameText plugin ++ "/" ++ instanceName, "Fetch: " ++ fetch] ++
      if null changes then ["No unacknowledged changes."] else [show kind ++ "  " ++ item | (EvidenceId item,kind) <- changes])
