{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Surfaces.GuestApi (modulesResult, moduleResult, symbolResult, workspaceResult, withOrigins) where

import Data.Aeson (Value(..), object, (.=), toJSON)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.Text as Text
import Data.List (partition, isPrefixOf)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.GuestApi
import Kyyn.Domain.Evolution (EvolutionWorkspace(..), evolutionIdName)
import Kyyn.Domain.Git (revisionName, Repository(..), TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (scopePath, scopedPath)
import Kyyn.Surfaces.Result (Response(..), Outcome(..), success, refusal)

withOrigins :: [ApiEntry] -> Response -> Response
withOrigins entries (Response outcome (Object fields) messages diagnostics)
  | outcome == Succeeded = Response outcome (Object enriched) displayed diagnostics
  where
    origins = [(Text.unpack entry.moduleName,label origin) | ApiEntry origin entry <- entries]
    label SdkOrigin = "sdk" :: String
    label GeneratedOrigin = "generated"
    label KbOrigin = "kb"
    label PluginOrigin = "plugin"
    listing = KeyMap.member "modules" fields
    selected = case KeyMap.lookup "module" fields of Just (String name) -> lookup (Text.unpack name) origins; _ -> Nothing
    enriched | listing = KeyMap.insert "origins" (object [Key.fromString name .= origin | (name,origin) <- origins]) fields
             | otherwise = maybe fields (\origin -> KeyMap.insert "origin" (String (Text.pack origin)) fields) selected
    displayed | listing = [name ++ maybe "" (\origin -> "  -- [" ++ origin ++ "]") (lookup name origins) | name <- messages]
              | otherwise = maybe messages (\origin -> ("-- [" ++ origin ++ "]") : messages) selected
withOrigins _ response = response

workspaceResult :: WorkspaceCatalogue -> Response -> Response
workspaceResult (WorkspaceCatalogue (EvolutionWorkspace (KnowledgeBase (Repository scope) prefix) identity) revision _) (Response outcome value text diagnostics) =
  Response outcome enriched
    (["Evolution " ++ evolutionIdName identity ++ " at " ++ location,
      "Before revision " ++ revisionName revision] ++ text) diagnostics
  where
    location = case prefix of WholeTree -> scopePath scope; Subtree path -> scopedPath scope path
    context = object ["kb" .= location, "evolution" .= evolutionIdName identity, "beforeRevision" .= revisionName revision]
    enriched = case value of
      Object fields -> Object (KeyMap.insert "context" context fields)
      _ -> object ["context" .= context, "result" .= value]

modulesResult :: Either [Diagnostic] [String] -> Response
modulesResult = either refusal (\modules -> success (object ["modules" .= modules]) modules)

moduleResult :: Either [Diagnostic] ApiModule -> Response
moduleResult = either refusal (\selected -> result (Text.unpack selected.moduleName)
  selected.moduleDocumentation selected.moduleExports (map Text.unpack selected.moduleInstances))

symbolResult :: Either [Diagnostic] (String,[ApiSymbol]) -> Response
symbolResult = either refusal (\(name,symbols) -> result name Nothing symbols [])

result :: String -> Maybe Text.Text -> [ApiSymbol] -> [String] -> Response
result name documentation symbols instances = success (object
  ["module" .= name, "documentation" .= documentation, "symbols" .= map toJSON symbols, "instances" .= instances])
  ((("module " ++ name) : comments documentation ++ concatMap symbolText ordered) ++ instanceText)
  where
    instanceText = if null instances then [] else ["", "-- Module instances"] ++ instances
    ordered | "Kyyn.Workspace." `isPrefixOf` name = let (local, exports) = partition definedHere symbols in local ++ exports
            | otherwise = symbols
    definedHere selected = (name ++ ".") `isPrefixOf` Text.unpack selected.exportOrigin

symbolText :: ApiSymbol -> [String]
symbolText selected = [""] ++ comments selected.exportDocumentation
  ++ ["-- [Defined as " ++ Text.unpack selected.exportOrigin ++ "]"]
  ++ lines (Text.unpack selected.exportSignature)

comments :: Maybe Text.Text -> [String]
comments = maybe [] (map (\line -> "-- " ++ line) . lines . Text.unpack)
