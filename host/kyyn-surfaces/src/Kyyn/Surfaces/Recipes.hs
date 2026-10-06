{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Recipes (recipesResult, recipeResult, recipeDescriptionResult, pendingResult, recipeRunResult) where

import Data.Aeson (Value, object, (.=))
import qualified Data.Text as Text
import Kyyn.Domain.Recipe (DescriptionFormat(..))
import Kyyn.Domain.Curation (Recipe(..), RecipeId(..), PendingEvidence(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Domain.Evidence (EvidenceSnapshotRef(..), ConnectorInstanceRef(..), FetchId(..), EvidenceId(..))
import Kyyn.Domain.Plugin (pluginNameText)
import Kyyn.Surfaces.Result (Response(..), success, workspaceResult)
import Kyyn.Domain.Evolution (EvolutionWorkspace(..), evolutionIdName)
import Kyyn.Domain.Git (GitRevision, revisionName)

recipeDescriptionResult :: GitRevision -> RecipeId -> DescriptionFormat -> (FlowEntryRef, Text.Text) -> Response
recipeDescriptionResult revision (RecipeId recipe) format (FlowEntryRef entry, rendered) = success
  (object ["kind" .= ("recipe-description" :: String), "recipe" .= recipe, "flow" .= entry,
    "revision" .= revisionName revision, "format" .= label, "description" .= rendered])
  (lines (Text.unpack rendered))
  where label = case format of Tree -> "tree" :: String; Dot -> "dot"; Mermaid -> "mermaid"

recipeRunResult :: EvolutionWorkspace -> GitRevision -> FilePath -> Response
recipeRunResult workspace@(EvolutionWorkspace _ identity) revision path =
  case workspaceResult workspace revision path of
    Response outcome value rendered diagnostics -> Response outcome value
      (rendered ++ ["Next: evolution check " ++ evolutionIdName identity ++ " (using the same --kb)"]) diagnostics

recipesResult :: [Fact Recipe] -> Response
recipesResult recipes = success (object ["recipes" .= map recipeJson recipes])
  (if null recipes then ["No recipes declared."] else [Text.unpack name | Fact (FactId name) _ <- recipes])

recipeResult :: Fact Recipe -> Response
recipeResult recipe@(Fact (FactId name) payload) = success (recipeJson recipe) [Text.unpack name,recipeText payload]

recipeJson :: Fact Recipe -> Value
recipeJson (Fact (FactId name) payload) = object ["name" .= name,"recipe" .= recipePayloadJson payload]

recipePayloadJson :: Recipe -> Value
recipePayloadJson (OpenAgent instructions) = object ["kind" .= ("OpenAgent" :: String),"instructions" .= instructions]
recipePayloadJson (ClosedAgent (FlowEntryRef entry)) = object ["kind" .= ("ClosedAgent" :: String),"flow" .= entry]

recipeText :: Recipe -> String
recipeText (OpenAgent instructions) = "Open agent: " ++ Text.unpack instructions
recipeText (ClosedAgent (FlowEntryRef entry)) = "Closed agent: " ++ Text.unpack entry

pendingResult :: RecipeId -> PendingEvidence -> Response
pendingResult (RecipeId recipe) (PendingEvidence (EvidenceSnapshotRef (ConnectorInstanceRef plugin instanceName) _ (FetchId fetch)) changes) =
  success (object ["recipe" .= recipe, "kind" .= ("Changes" :: String),
    "scope" .= object ["plugin" .= pluginNameText plugin,"instance" .= instanceName,"fetch" .= fetch],
    "changes" .= [object ["id" .= item,"kind" .= show kind] | (EvidenceId item,kind) <- changes]])
    (["Recipe: " ++ Text.unpack recipe, "Evidence: " ++ pluginNameText plugin ++ "/" ++ instanceName, "Fetch: " ++ fetch,
      "Scope: EvidenceScope " ++ unwords (map show [pluginNameText plugin,instanceName,fetch])] ++
      if null changes then ["No unacknowledged changes."] else [show kind ++ "  " ++ Text.unpack item | (EvidenceId item,kind) <- changes])
pendingResult (RecipeId recipe) (Reconciliation (EvidenceSnapshotRef (ConnectorInstanceRef plugin instanceName) _ (FetchId fetch)) ids) =
  success (object ["recipe" .= recipe, "kind" .= ("Reconciliation" :: String),
    "scope" .= object ["plugin" .= pluginNameText plugin,"instance" .= instanceName,"fetch" .= fetch],
    "currentIds" .= [item | EvidenceId item <- ids]])
    (["Recipe: " ++ Text.unpack recipe, "Evidence: " ++ pluginNameText plugin ++ "/" ++ instanceName, "Fetch: " ++ fetch,
      "Producer changed: reconcile the current evidence with the root.",
      "Scope: EvidenceScope " ++ unwords (map show [pluginNameText plugin,instanceName,fetch]),
      "Acknowledge the entire batch or leave it pending."] ++
      if null ids then ["The current evidence set is empty."] else [Text.unpack item | EvidenceId item <- ids])
