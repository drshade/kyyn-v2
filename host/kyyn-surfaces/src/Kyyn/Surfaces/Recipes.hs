{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Recipes (recipesResult, recipeResult, recipeDescriptionResult, recipeRunResult) where

import Kyyn.Domain.RecipeRun (RecipeRunId, runIdText)
import qualified Data.Aeson.KeyMap as Keys
import Data.Aeson (Value(..), object, (.=))
import qualified Data.Text as Text
import Kyyn.Domain.Recipe (DescriptionFormat(..), RecipeDefinition(..))
import Kyyn.Domain.Recipe (RecipeId(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (Lifetime, lifetimeName, FlowEntryRef(..))
import Kyyn.Surfaces.Result (Response(..), success, workspaceResult)
import Kyyn.Domain.Evolution (EvolutionWorkspace(..), evolutionIdName)
import Kyyn.Domain.Git (GitRevision, revisionName)

recipeDescriptionResult :: GitRevision -> RecipeId -> DescriptionFormat -> (Lifetime, FlowEntryRef, Text.Text) -> Response
recipeDescriptionResult revision (RecipeId recipe) format (lifetime, FlowEntryRef entry, rendered) = success
  (object ["kind" .= ("recipe-description" :: String), "recipe" .= recipe, "lifetime" .= lifetime,"flow" .= entry,
    "revision" .= revisionName revision, "format" .= label, "description" .= rendered])
  (lines (Text.unpack rendered))
  where label = case format of Tree -> "tree" :: String; Dot -> "dot"; Mermaid -> "mermaid"

recipeRunResult :: RecipeRunId -> EvolutionWorkspace -> GitRevision -> FilePath -> Response
recipeRunResult run workspace@(EvolutionWorkspace _ identity) revision path =
  case workspaceResult workspace revision path of
    Response outcome value rendered diagnostics -> Response outcome (addRun value)
      (rendered ++ ["Run: " ++ runIdText run, "Next: evolution check " ++ evolutionIdName identity ++ " (using the same --kb)"]) diagnostics

  where
    addRun (Object fields) = Object (Keys.insert "runId" (String (Text.pack (runIdText run)))
      (Keys.insert "runUrl" (String (Text.pack ("/runs/" ++ runIdText run))) fields))
    addRun value = value

recipesResult :: [Fact RecipeDefinition] -> Response
recipesResult recipes = success (object ["recipes" .= map recipeJson recipes])
  (if null recipes then ["No recipes declared."] else [Text.unpack name ++ " — " ++ summary method | Fact (FactId name) method <- recipes])
  where
    summary (OpenRecipe lifetime _ _) = lifetimeName lifetime ++ " open agent"
    summary (ClosedRecipe lifetime _) = lifetimeName lifetime ++ " closed flow"

recipeResult :: Fact RecipeDefinition -> Response
recipeResult recipe@(Fact (FactId name) payload) = success (recipeJson recipe) [Text.unpack name,recipeText payload]

recipeJson :: Fact RecipeDefinition -> Value
recipeJson (Fact (FactId name) payload) = object ["name" .= name,"recipe" .= recipePayloadJson payload]

recipePayloadJson :: RecipeDefinition -> Value
recipePayloadJson (OpenRecipe lifetime instructions stateType) = object ["kind" .= ("OpenAgent" :: String),"lifetime" .= lifetime,"instructions" .= instructions,"stateType" .= stateType]
recipePayloadJson (ClosedRecipe lifetime (FlowEntryRef entry)) = object ["kind" .= ("ClosedAgent" :: String),"lifetime" .= lifetime,"flow" .= entry]

recipeText :: RecipeDefinition -> String
recipeText (OpenRecipe lifetime instructions stateType) = lifetimeName lifetime ++ " open agent: " ++ Text.unpack instructions ++ "\nState type: " ++ stateType
recipeText (ClosedRecipe lifetime (FlowEntryRef entry)) = lifetimeName lifetime ++ " closed agent: " ++ Text.unpack entry
