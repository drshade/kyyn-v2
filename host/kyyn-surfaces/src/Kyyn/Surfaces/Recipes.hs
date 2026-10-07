{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Recipes (recipesResult, recipeResult, recipeDescriptionResult, recipeRunResult) where

import Data.Aeson (Value, object, (.=))
import qualified Data.Text as Text
import Kyyn.Domain.Recipe (DescriptionFormat(..), RecipeDefinition(..))
import Kyyn.Domain.Curation (RecipeId(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
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

recipesResult :: [Fact RecipeDefinition] -> Response
recipesResult recipes = success (object ["recipes" .= map recipeJson recipes])
  (if null recipes then ["No recipes declared."] else [Text.unpack name | Fact (FactId name) _ <- recipes])

recipeResult :: Fact RecipeDefinition -> Response
recipeResult recipe@(Fact (FactId name) payload) = success (recipeJson recipe) [Text.unpack name,recipeText payload]

recipeJson :: Fact RecipeDefinition -> Value
recipeJson (Fact (FactId name) payload) = object ["name" .= name,"recipe" .= recipePayloadJson payload]

recipePayloadJson :: RecipeDefinition -> Value
recipePayloadJson (OpenRecipe instructions stateType) = object ["kind" .= ("OpenAgent" :: String),"instructions" .= instructions,"stateType" .= stateType]
recipePayloadJson (ClosedRecipe (FlowEntryRef entry)) = object ["kind" .= ("ClosedAgent" :: String),"flow" .= entry]

recipeText :: RecipeDefinition -> String
recipeText (OpenRecipe instructions stateType) = "Open agent: " ++ Text.unpack instructions ++ "\nState type: " ++ stateType
recipeText (ClosedRecipe (FlowEntryRef entry)) = "Closed agent: " ++ Text.unpack entry
