-- GHC-owned export inspection: source closure, explicit exports, namespaces,
-- record fields without selectors, and source rejection before an adapter exists.
{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (unless)
import Data.List (sort)
import qualified Data.Text as Text
import System.Directory (withCurrentDirectory)
import System.Process (readProcess)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Build.Inspection
import Kyyn.Build.Manifest (parseManifest, parsePluginManifest, parseInstances, ConfiguredInstance(..))
import Kyyn.Types.Guest

main :: IO ()
main = do
  compilerOutput <- readProcess "ghc" ["--print-libdir"] ""
  libdir <- case lines compilerOutput of
    [path] -> pure path
    _ -> fail "Compiler did not identify its libdir"
  withSystemTempDirectory "kyyn-ghc-inspection" $ \directory -> withCurrentDirectory directory $ do
    writeFile "Types.hs" (unlines
      ["{-# LANGUAGE NoFieldSelectors #-}","module Types (Root(..)) where",
       "data Root = Root { count :: Integer } deriving Eq"])
    writeFile "Schema.hs" (unlines
      ["module Schema (Root(..), total) where","import Types",
       "-- | Count selected records.","total :: Root -> Integer","total (Root n) = n", "private :: Bool", "private = True"])
    (sources,modules) <- inspectExports libdir ["."] [] ["Schema","Schema","Types"]
    unless (sort sources == ["Schema.hs","Types.hs"]) (fail ("Wrong schema closure: " ++ show sources))
    let exports = concatMap moduleExports modules
        values = [(entry.exportName,entry.exportKind) | entry <- exports]
    unless (("Root",ExportType) `elem` values && ("Root",ExportConstructor) `elem` values && ("total",ExportValue) `elem` values)
      (fail ("Compiler export namespaces missing: " ++ show values))
    unless (all ((/= "private") . exportName) exports) (fail "Private implementation leaked into API")
    unless (any (\entry -> entry.exportName == "total" &&
      maybe False ("Count selected records." `Text.isInfixOf`) entry.exportDocumentation) exports)
      (fail "GHC Haddock documentation missing")
    unless (any (\entry -> entry.exportName == "Root" && entry.exportOrigin == "Types.Root") exports)
      (fail "Re-export lost its defining origin")
    unless (any (\selected -> selected.moduleName == "Types" &&
      any ("Eq Root" `Text.isInfixOf`) selected.moduleInstances) modules)
      (fail "Compiler-owned module instances missing")
    unless (any (\entry -> entry.exportName == "total" && "Integer" `Text.isInfixOf` entry.exportSignature) exports)
      (fail "Compiler signature missing")
    (packageSources,packageModules) <- inspectExports libdir ["."] [] ["Data.Maybe"]
    unless (null packageSources && any ((== "fromMaybe") . exportName) (concatMap moduleExports packageModules))
      (fail "Locked library export inspection failed")
    -- Force interface-only fields too: package ModuleInfo contains a partial
    -- instance accessor even though its exports can be inspected successfully.
    sum [Text.length text | m <- packageModules, text <- m.moduleInstances] `seq` pure ()
    writeFile "Main.hs" (unlines ["module Main (value) where","value :: Integer","value = 1"])
    (_,mainModules) <- inspectExports libdir ["."] [] ["Main"]
    unless (any ((== "value") . exportName) (concatMap moduleExports mainModules)) (fail "Authored Main required an IO entry")
    writeFile "UsesBindings.hs" (unlines
      ["module UsesBindings where", "import KyynQueryBindings", "selected = missing"])
    uses <- requiredBindings libdir ["."] [] ["UsesBindings"]
    independent <- requiredBindings libdir ["."] [] ["Schema","Data.Maybe"]
    unless (uses == BindingNeeds True False && independent == BindingNeeds False False) (fail "Root prepass selection ignored compiler dependency closure")
    writeFile "UsesTools.hs" (unlines
      ["module UsesTools where", "import Kyyn.Connectors", "import Kyyn.Plugins.P_local_file.Files", "selected = files"])
    writeFile "Indirect.hs" (unlines ["module Indirect where", "import UsesTools", "other = selected"])
    toolNeeds <- requiredBindings libdir ["."] [] ["Indirect"]
    directNeeds <- requiredBindings libdir ["."] [] ["Kyyn.Connectors"]
    unless (toolNeeds == BindingNeeds False True && directNeeds == toolNeeds)
      (fail "Generated tool imports were lost from the partial compiler graph")
    writeFile "Broken.hs" (unlines ["module Broken where","bad :: Integer","bad = True"])
    failed <- try (inspectExports libdir ["."] [] ["Broken"]) :: IO (Either SomeException ([FilePath],[ModuleDescription]))
    case failed of
      Left _ -> pure ()
      Right _ -> fail "Invalid authored source passed compiler inspection"
  putStrLn "GHC export inspection and source rejection checks passed."
  unless (parsePluginManifest "{ name = \"local-file\", entryModule = \"Fixture.Plugin\" }" == Right ("local-file","Fixture.Plugin"))
    (fail "Valid plugin manifest rejected")
  mapM_ (\source -> case parsePluginManifest source of
    Left _ -> pure ()
    Right _ -> fail "Malformed plugin manifest accepted")
    ["./outside.dhall", "{ name = \"../escape\", entryModule = \"Fixture.Plugin\" }",
     "{ name = \"valid\", entryModule = \"Fixture; injected\" }",
     "{ name = \"valid\", entryModule = \"Fixture.Plugin\", extra = True }"]
  unless (parseInstances "[{ name = \"reader\", binding = \"files\", connector = < Files : Integer >.Files +10 }]"
      == Right [ConfiguredInstance "reader" "files" "Files"])
    (fail "Configured connector binding was not decoded")
  case parseInstances "./outside.dhall" of
    Left _ -> pure ()
    Right _ -> fail "Configuration import accepted"
  let validManifest = Text.unlines
        ["{ schemaType = \"Schema.Root\", schemaMetadata = \"Schema.metadata\", validator = \"Schema.validate\"",
         ", queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }",
         ", tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }"]
  case parseManifest validManifest of
    Left problem -> fail problem
    Right _ -> pure ()
  let rejects source = case parseManifest source of
        Left _ -> pure ()
        Right _ -> fail "Malformed manifest accepted"
  rejects "./some-other-manifest.dhall"
  rejects (Text.replace "Schema.Root" "Schema.Root; error \"injected\"" validManifest)
  rejects (Text.replace "Schema.validate" "validate" validManifest)
  rejects (Text.replace ", tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }"
    ", tools = [] : List Natural" validManifest)
  putStrLn "Manifest references, imports and empty-list type checks passed."
