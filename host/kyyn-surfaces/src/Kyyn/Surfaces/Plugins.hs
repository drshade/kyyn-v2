{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Plugins (pluginListResult, pluginDescriptionResult, pluginGuideResult) where

import Data.Aeson (Value, object, (.=))
import Kyyn.Domain.Evolution (EvolutionId, evolutionIdName)
import Kyyn.Domain.Git (GitRevision, revisionName, TreePath(..), gitUrlText)
import Kyyn.Domain.Path (scopePath, relativeName)
import Kyyn.Domain.Plugin
import Kyyn.Surfaces.Result (Response, success)

pluginListResult :: [PluginName] -> Response
pluginListResult names = success (object ["plugins" .= map pluginNameText names])
  (if null names then ["No installed plugins"] else map pluginNameText names)

pluginDescriptionResult :: Maybe EvolutionId -> GitRevision -> PluginDescription -> Response
pluginDescriptionResult evolution revision description@(PluginDescription manifest (PluginOrigin _ _ originRevision) hasGuide) =
  success (details evolution revision description)
    ["Plugin " ++ pluginNameText (manifestName manifest), "Entry module: " ++ entryModule manifest,
     "Installed from revision: " ++ revisionName originRevision,
     if hasGuide then "Guide: kyyn-v2 plugin guide " ++ pluginNameText (manifestName manifest) ++ target evolution
       else "No README.md guide in this package",
     "Configuration: kyyn-v2 plugin connector schema show " ++ pluginNameText (manifestName manifest) ++ target evolution]

pluginGuideResult :: Maybe EvolutionId -> GitRevision -> PluginGuide -> Response
pluginGuideResult evolution revision (PluginGuide description markdown) =
  success (object ["package" .= details evolution revision description, "markdown" .= markdown]) [markdown]

details :: Maybe EvolutionId -> GitRevision -> PluginDescription -> Value
details evolution revision (PluginDescription manifest (PluginOrigin repository path originRevision) hasGuide) = object
  ["name" .= pluginNameText (manifestName manifest), "entryModule" .= entryModule manifest,
   "hasGuide" .= hasGuide, "evolution" .= fmap evolutionIdName evolution,
   "acceptedRevision" .= (if evolution == Nothing then Just (revisionName revision) else Nothing),
   "origin" .= object ["source" .= source, "path" .= selected, "revision" .= revisionName originRevision]]
  where
    source = case repository of LocalRepository scope -> scopePath scope; RemoteRepository url -> gitUrlText url
    selected = case path of WholeTree -> Nothing; Subtree value -> Just (relativeName value)

target :: Maybe EvolutionId -> String
target = maybe "" ((" --evolution " ++) . evolutionIdName)
