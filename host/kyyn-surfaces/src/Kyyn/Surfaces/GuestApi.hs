{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.GuestApi (modulesResult, moduleResult, symbolResult, workspaceResult, availableCatalogue, withOrigins) where

import Data.Aeson (Value(..), object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.Text as Text
import Data.Char (isAlpha)
import Data.List (intercalate, partition, isPrefixOf)
import Kyyn.Domain.Diagnostic (Diagnostic(..), Severity(..))
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
    origins = [(name,label origin) | ApiEntry origin (ApiModule name _ _) <- entries]
    label SdkOrigin = "sdk" :: String
    label GeneratedOrigin = "generated"
    label KbOrigin = "kb"
    listing = KeyMap.member "modules" fields
    selected = case KeyMap.lookup "module" fields of Just (String name) -> lookup (Text.unpack name) origins; _ -> Nothing
    enriched | listing = KeyMap.insert "origins" (object [Key.fromString name .= origin | (name,origin) <- origins]) fields
             | otherwise = maybe fields (\origin -> KeyMap.insert "origin" (String (Text.pack origin)) fields) selected
    displayed | listing = [name ++ maybe "" (\origin -> "  -- [" ++ origin ++ "]") (lookup name origins) | name <- messages]
              | otherwise = maybe messages (\origin -> ("-- [" ++ origin ++ "]") : messages) selected
withOrigins _ response = response

availableCatalogue :: Bool -> [ApiModule] -> Response -> Response
availableCatalogue listing modules response@(Response outcome _ _ diagnostics)
  | outcome == Succeeded = response
  | any missingSymbol diagnostics = response
  | otherwise = case withOrigins (map (ApiEntry SdkOrigin) modules) (modulesResult (Right [name | ApiModule name _ _ <- modules])) of
      Response _ value messages _ -> Response (if listing then Succeeded else outcome) value messages
        (Diagnostic (if listing then Warning else Error) "guest.bindings-unavailable"
          "KB API inspection failed; the installed SDK catalogue is shown. Fix the reported problem and retry."
          Nothing : map severity diagnostics)
  where
    missingSymbol (Diagnostic _ code _ _) = code == "guest.module-not-found" || code == "guest.symbol-not-found"
    severity (Diagnostic level code message location) =
      Diagnostic (if listing then Warning else level) code message location

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
moduleResult = either refusal (\(ApiModule name symbols instances) -> result name symbols instances)

symbolResult :: Either [Diagnostic] (String,[ApiSymbol]) -> Response
symbolResult = either refusal (\(name,symbols) -> result name symbols [])

result :: String -> [ApiSymbol] -> [String] -> Response
result name symbols instances = success (object
  ["module" .= name, "symbols" .= map symbolJson symbols, "instances" .= instances])
  ((("module " ++ name) : concatMap symbolText ordered) ++ instanceText)
  where
    instanceText = if null instances then [] else ["", "-- Explicit instances declared here"] ++ instances
    ordered | "Kyyn.Workspace." `isPrefixOf` name = let (local, exports) = partition definedHere symbols in local ++ exports
            | otherwise = symbols
    definedHere (ApiSymbol _ _ origin _ _ _) = (name ++ ".") `isPrefixOf` origin

symbolJson :: ApiSymbol -> Value
symbolJson (ApiSymbol name namespace origin signature declaration documentation) = object
  [ "name" .= name, "namespace" .= namespaceName namespace, "definedAs" .= origin
  , "checkedSignature" .= signature, "declaration" .= declaration, "documentation" .= documentation ]

namespaceName :: Namespace -> String
namespaceName TypeNamespace = "type"
namespaceName ValueNamespace = "value"

symbolText :: ApiSymbol -> [String]
symbolText (ApiSymbol name namespace origin signature declaration documentation) =
  [""] ++ maybe [] (map comment . lines) documentation
  ++ ["-- [Defined as " ++ displayOrigin name origin ++ "]"]
  ++ maybe [prefix ++ signatureName name ++ " :: " ++ signature ++ "  -- [compiler signature]"] lines declaration
  where
    prefix = case namespace of TypeNamespace -> "type "; ValueNamespace -> ""
    comment "" = "--"
    comment text = "-- " ++ text

signatureName :: String -> String
signatureName name@(c:_) | isAlpha c || c `elem` ['_', '(', '['] = name
signatureName name = "(" ++ name ++ ")"

displayOrigin :: String -> String -> String
displayOrigin name origin = case reverse (segments origin) of
  field : _record : "get$" : owner@(_:_) | field == name ->
    intercalate "." (reverse owner ++ [field])
  _ -> origin
  where
    segments text = case break (== '.') text of
      (part,[]) -> [part]
      (part,_:rest) -> part : segments rest
