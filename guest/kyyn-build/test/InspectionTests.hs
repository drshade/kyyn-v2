-- GHC-owned export inspection: source closure, explicit exports, namespaces,
-- record fields without selectors, dependency-only closure equivalence, and source
-- rejection before an adapter exists.
{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (unless)
import Data.List (sort)
import qualified Data.Text as Text
import System.Directory (withCurrentDirectory, listDirectory, doesDirectoryExist, createDirectory, copyFile, removeFile)
import System.Process (readProcess, readProcessWithExitCode)
import System.Environment (getArgs)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Build.Inspection
import Kyyn.Build.Manifest (parseManifest, parsePluginManifest, parseInstances, ConfiguredInstance(..))
import Kyyn.Types.Guest

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--output-fixture",compiler,helper,fixture] -> rejectOutputMismatch compiler helper fixture
    [] -> checkInspection
    _ -> fail "Expected --output-fixture COMPILER BUILD_HELPER FIXTURE or no arguments"

-- Use the exact Nix compiler/helper that built the positive output fixture.
-- The changed query is valid by itself; only the sink binding is ill-typed.
rejectOutputMismatch :: FilePath -> FilePath -> FilePath -> IO ()
rejectOutputMismatch compiler helper fixture = withSystemTempDirectory "kyyn-output-mismatch" $ \directory -> do
  copyTree fixture directory
  let query = directory </> "src/OutputQueries.hs"
  removeFile query
  writeFile query (unlines
    ["module OutputQueries where", "import Data.Text (Text, pack)",
     "import Kyyn.Schema (SchemaMetadata(..))", "import Kyyn.Types.Query (Query)", "import Main (Root)",
     "type Arguments = ()", "type Result = Text", "metadata = SchemaMetadata [] [] []",
     "count :: Arguments -> Query Root Result", "count _ = pure (pack \"incompatible sink input\")"])
  (status,output,errors) <- readProcessWithExitCode helper [compiler,directory,directory </> "guest"] ""
  unless (status /= ExitSuccess && "KyynOutputBindings.hs" `Text.isInfixOf` Text.pack (output ++ errors)
    && "output_snapshot_0" `Text.isInfixOf` Text.pack errors
    && "Integer" `Text.isInfixOf` Text.pack errors && "Text" `Text.isInfixOf` Text.pack errors)
    (fail ("Wrong outcome for incompatible query/sink types: " ++ output ++ errors))
  putStrLn "GHC rejects an incompatible query/sink binding in the selected guest environment."
  where
    copyTree source target = listDirectory source >>= mapM_ (\name -> do
      let from = source </> name; to = target </> name
      directory <- doesDirectoryExist from
      if directory then createDirectory to >> copyTree from to else copyFile from to)

checkInspection :: IO ()
checkInspection = do
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
    dependencies <- sourceDependencies libdir ["."] [] ["Schema","Schema","Types"]
    unless (dependencies == sources) (fail "Dependency-only paths differ from checked closure")
    schemaOnly <- sourceDependencies libdir ["."] [] ["Types"]
    unless (schemaOnly == ["Types.hs"]) (fail "Unrelated inspected modules leaked into contract closure")
    libraryOnly <- sourceDependencies libdir ["."] [] ["Data.Maybe"]
    unless (null libraryOnly) (fail "Package module acquired authored source dependencies")
    -- Dependencies must reflect current generated imports, not a previous phase.
    writeFile "Generated.hs" "module Generated where\nimport Types\n"
    firstClosure <- sourceDependencies libdir ["."] [] ["Generated"]
    writeFile "Generated.hs" "module Generated where\nimport Schema\n"
    nextClosure <- sourceDependencies libdir ["."] [] ["Generated"]
    (checkedClosure,_) <- inspectExports libdir ["."] [] ["Generated"]
    unless (firstClosure == ["Generated.hs","Types.hs"] && nextClosure == checkedClosure &&
      nextClosure == ["Generated.hs","Schema.hs","Types.hs"])
      (fail "Changed generated imports reused stale source dependencies")
    writeFile "Conditional.hs" (unlines
      ["{-# LANGUAGE CPP #-}", "module Conditional where", "#ifdef USE_SCHEMA",
       "import Schema", "#else", "import Types", "#endif"])
    let equivalent names options = do
          (checked,_) <- inspectExports libdir ["."] options names
          paths <- sourceDependencies libdir ["."] options names
          unless (checked == paths) (fail ("Dependency closure differs for " ++ show names))
    equivalent ["Conditional"] []
    equivalent ["Conditional"] ["-DUSE_SCHEMA"]
    writeFile "CycleA.hs-boot" "module CycleA where\ndata A\n"
    writeFile "CycleA.hs" "module CycleA where\nimport CycleB\ndata A = A\nvalue = b\n"
    writeFile "CycleB.hs" "module CycleB where\nimport {-# SOURCE #-} CycleA\nb :: Maybe A\nb = Nothing\n"
    equivalent ["CycleA"] []
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
    -- Same-occurrence Before/After types must remain distinguishable to authors.
    writeFile "Before.hs" "module Before where\ndata Root = Root\n"
    writeFile "After.hs" "module After where\ndata Root = Root\n"
    writeFile "Migration.hs" (unlines
      ["module Migration (change) where", "import qualified Before", "import qualified After",
       "change :: Before.Root -> After.Root", "change _ = After.Root"])
    (_,migration) <- inspectExports libdir ["."] [] ["Migration"]
    let signatures = [entry.exportSignature | m <- migration, entry <- m.moduleExports, entry.exportName == "change"]
    unless (case signatures of [signature] -> all (`Text.isInfixOf` signature) ["Before.Root","After.Root"]; _ -> False)
      (fail ("Compiler signature obscures endpoint identity: " ++ show signatures))
    writeFile "Internal.hs" "module Internal where\ndata Hidden = HiddenConstructor\n"
    writeFile "Sibling.hs" "module Sibling where\ndata Other = HiddenConstructor\n"
    writeFile "Public.hs" "module Public (Hidden, Other(..)) where\nimport Internal (Hidden)\nimport Sibling (Other(..))\n"
    (_,concrete) <- inspectExports libdir ["."] [] ["Internal"]
    unless (any (Text.isInfixOf "HiddenConstructor" . exportSignature) (concatMap moduleExports concrete))
      (fail "Exported constructors disappeared from compiler declarations")
    (_,abstract) <- inspectExports libdir ["."] [] ["Public"]
    unless (all (not . Text.isInfixOf "HiddenConstructor" . exportSignature) ([entry | m <- abstract, entry <- m.moduleExports, entry.exportName == "Hidden"]))
      (fail "Abstract exported type disclosed its hidden constructor")
    writeFile "Facade.hs" "module Facade (keep) where\nimport Public (Hidden)\nkeep :: Hidden -> Hidden\nkeep = id\n"
    (_,facade) <- inspectExports libdir ["."] [] ["Facade"]
    unless (all (not . Text.isInfixOf "Internal." . exportSignature) (concatMap moduleExports facade))
      (fail "Compiler signature ignores the authored public imports")
    writeFile "UsesBindings.hs" (unlines
      ["module UsesBindings where", "import KyynQueryBindings", "selected = missing"])
    uses <- requiredBindings libdir ["."] [] ["UsesBindings"]
    independent <- requiredBindings libdir ["."] [] ["Schema","Data.Maybe"]
    unless (uses == BindingNeeds True False False && independent == BindingNeeds False False False) (fail "Root prepass selection ignored compiler dependency closure")
    writeFile "UsesTools.hs" (unlines
      ["module UsesTools where", "import Kyyn.Connectors", "import Kyyn.Plugins.P_local_file.Files", "selected = files"])
    writeFile "Indirect.hs" (unlines ["module Indirect where", "import UsesTools", "other = selected"])
    toolNeeds <- requiredBindings libdir ["."] [] ["Indirect"]
    directNeeds <- requiredBindings libdir ["."] [] ["Kyyn.Connectors"]
    unless (toolNeeds == BindingNeeds False True False && directNeeds == toolNeeds)
      (fail "Generated tool imports were lost from the partial compiler graph")
    writeFile "UsesWorkspace.hs" "module UsesWorkspace where\nimport Kyyn.Workspace.After\nunfinished =\n"
    workspaceNeeds <- requiredBindings libdir ["."] [] ["UsesWorkspace"]
    unless (workspaceNeeds == BindingNeeds False False True)
      (fail "Dependency-scoped discovery lost generated workspace imports")
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
