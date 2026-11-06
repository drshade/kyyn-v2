{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Build.Driver (buildGuest) where

import Control.Monad (unless, forM, when)
import Data.Aeson (eitherDecodeStrict')
import qualified Data.ByteString as Bytes
import Data.Char (isAlphaNum, isLower)
import Data.List (nub, intercalate)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import System.Directory (createDirectoryIfMissing, doesFileExist, doesPathExist, makeAbsolute, withCurrentDirectory)
import System.FilePath ((</>), takeDirectory, takeBaseName)
import System.Process (callProcess, readProcess)
import Kyyn.Build.Inspection
import Kyyn.Build.Plugins
import qualified Kyyn.Types.Plugin as P
import Kyyn.Build.Manifest
import Kyyn.Types.Guest
import Kyyn.Types.GuestBuild
import Kyyn.Types.SchemaMetadata

-- The compiler and source are selected by the KB's build, never the host's PATH.
-- Both inspection and compilation use that exact compiler package environment.
buildGuest :: FilePath -> FilePath -> FilePath -> IO ()
buildGuest compiler source output = do
  destination <- makeAbsolute output
  withCurrentDirectory source $ do
    hasSelection <- doesFileExist ".kyyn-build.json"
    selection <- if hasSelection then Bytes.readFile ".kyyn-build.json" >>= either fail pure . eitherDecodeStrict'
      else pure RootEntries
    libdir <- readProcess compiler ["--print-libdir"] "" >>= singleLine "compiler libdir"
    packages <- packageOptions libdir
    let generated = ".kyyn-generated"
    occupied <- or <$> traverse doesFileExist
      ["src" </> moduleName ++ extension | moduleName <- ["KyynQueryBindings","KyynGuestSchemaEntry","KyynGuestEntry","KyynGuestRegistrations"],
        extension <- [".hs",".lhs"]]
    unless (not occupied) (fail "Authored source collides with a generated guest module")
    existing <- doesPathExist generated
    unless (not existing) (fail "Guest build requires a fresh .kyyn-generated directory")
    createDirectoryIfMissing True generated
    case selection of
      DiscoveryEntries (ModuleExports modules) -> do
        let selectedModules = map Text.unpack modules
        needsRoot <- needsRootBindings libdir ["src"] packages selectedModules
        when needsRoot $ do
          manifest <- Text.readFile "kb.dhall" >>= either fail pure . parseManifest
          _ <- prepareRoot compiler libdir generated packages ["src"] manifest
          pure ()
        (_,exports) <- inspectExports libdir ["src",generated] packages selectedModules
        writeFile (generated </> "KyynGuestEntry.hs") (unlines
          ["{-# LANGUAGE OverloadedStrings #-}","module KyynGuestEntry where", "import Kyyn.Runtime.Guest",
           "import Kyyn.Types.Guest", "import System.Environment (getArgs)",
           "main :: IO ()", "main = do", "  arguments <- getArgs", "  case arguments of",
           "    [\"--check-build\"] -> checkEntries []",
           "    [] -> runGuest " ++ showExports exports ++ " []",
           "    _ -> fail \"Unexpected guest arguments\""])
        finishGuest compiler generated packages destination
      RootEntries -> buildRoot compiler libdir generated packages destination selection
      DiscoveryEntries RootSchema -> buildRoot compiler libdir generated packages destination selection
      EvolutionEntry -> fail "Evolution guest build is not implemented yet"

buildRoot :: FilePath -> FilePath -> FilePath -> [String] -> FilePath -> GuestSelection -> IO ()
buildRoot compiler libdir generated basePackages destination selection = do
  plugins <- discoverPlugins
  let roots = "src" : map sourceRoot plugins
      packages = basePackages ++ map ("-i" ++) roots
  registrations <- if selection == RootEntries
    then bootstrapPlugins (\pluginRoots -> compile compiler generated "registrations" (basePackages ++ map ("-i" ++) pluginRoots)) generated plugins
    else pure []
  let captured = [(plugin,connector.name,method) | RegisteredPlugin plugin connectors <- registrations,
        connector@P.SourceConnector{} <- connectors, method <- connector.methods]
  capturedEntries <- forM captured $ \(plugin,connector,method) -> do
    implementation <- either fail pure (qualifiedReference False method.implementation)
    (sources,_) <- inspectExports libdir (roots ++ [generated]) packages [Text.unpack (referenceModule implementation)]
    let name = Text.intercalate "." [plugin.pluginName,connector,method.methodName]
        identity = "(CapturedMethodIdentity " ++ unwords (map show
          [plugin.pluginName,connector,method.methodName,method.methodDescription]) ++ ")"
    pure (implementation,"capturedReadEntry " ++ show name ++ " " ++ identity ++ " " ++ show sources ++ " " ++ Text.unpack method.implementation)
  acquisitionEntries <- forM
    [(plugin,connector) | RegisteredPlugin plugin connectors <- registrations, connector@P.SourceConnector{} <- connectors] $
      \(plugin,connector) -> do
        implementation <- either fail pure (qualifiedReference False connector.fetch)
        (sources,_) <- inspectExports libdir (roots ++ [generated]) packages [Text.unpack (referenceModule implementation)]
        let name = "$acquisition." <> plugin.pluginName <> "." <> connector.name
            identity = "(ConnectorIdentity " ++ show plugin.pluginName ++ " " ++ show connector.name ++ ")"
        pure (implementation,"acquisitionEntry " ++ show name ++ " " ++ identity ++ " " ++ show sources ++ " " ++ Text.unpack connector.fetch)
  let pluginEntries = capturedEntries ++ acquisitionEntries
  manifest <- Text.readFile "kb.dhall" >>= either fail pure . parseManifest
  unless (selection /= RootEntries || (null manifest.tools && null manifest.outputs))
    (fail "Guest build: tool and output adapters are not implemented yet")
  let name = Text.unpack . referenceName
      moduleName = Text.unpack . referenceModule
      rootModules = nub [moduleName manifest.schemaType,moduleName manifest.schemaMetadata]
      selectedQueries = if selection == RootEntries then manifest.queries else []
  rootSources <- prepareRoot compiler libdir generated packages roots manifest
  let selectedModules = nub (rootModules ++ [moduleName manifest.validator | selection == RootEntries] ++ concat
        [[moduleName q.queryImplementation,moduleName q.inputType,moduleName q.inputMetadata,
          moduleName q.resultType,moduleName q.resultMetadata] | q <- selectedQueries] ++ map (moduleName . fst) pluginEntries)
  (_,exports) <- inspectExports libdir (roots ++ [generated]) packages selectedModules
  querySources <- forM selectedQueries $ \q -> do
    (arguments,_) <- inspectExports libdir (roots ++ [generated]) packages [moduleName q.inputType]
    (results,_) <- inspectExports libdir (roots ++ [generated]) packages [moduleName q.resultType]
    pure (q,arguments,results)
  let rootEntry = if selection == RootEntries
        then "validationEntry @" ++ name manifest.schemaType ++ " " ++ name manifest.schemaMetadata ++ " " ++ show rootSources ++ " " ++ name manifest.validator
        else "describeEntry @" ++ name manifest.schemaType ++ " \"root\" " ++ name manifest.schemaMetadata ++ " " ++ show rootSources
  writeFile (generated </> "KyynGuestEntry.hs") (unlines
    (["{-# LANGUAGE TypeApplications, OverloadedStrings #-}","module KyynGuestEntry where",
      "import Kyyn.Runtime.Guest", "import Kyyn.Types.Guest", "import Kyyn.Contract (ProjectionError)",
      "import System.Environment (getArgs)"] ++
     map ("import qualified " ++) selectedModules ++
     ["main :: IO ()", "main = do", "  arguments <- getArgs", "  case arguments of",
      "    [\"--check-build\"] -> checkEntries selected",
      "    [] -> runGuest " ++ showExports exports ++ " selected",
      "    _ -> fail \"Unexpected guest arguments\"",
      "selected :: [Either ProjectionError Entry]", "selected = [" ++
      intercalate ",\n  "
        (rootEntry : map snd pluginEntries ++
         ["queryEntry @" ++ name manifest.schemaType ++ " @" ++ name q.inputType ++ " @" ++ name q.resultType ++
          " " ++ show (Text.unpack q.queryName) ++
          " (" ++ name manifest.schemaMetadata ++ "," ++ show rootSources ++ ")" ++
          " (" ++ name q.inputMetadata ++ "," ++ show arguments ++ ")" ++
          " (" ++ name q.resultMetadata ++ "," ++ show results ++ ") " ++ name q.queryImplementation
            | (q,arguments,results) <- querySources]) ++ "]"]))
  finishGuest compiler generated packages destination

prepareRoot :: FilePath -> FilePath -> FilePath -> [String] -> [FilePath] -> Manifest -> IO [FilePath]
prepareRoot compiler libdir generated packages roots manifest = do
  let name = Text.unpack . referenceName
      moduleName = Text.unpack . referenceModule
      rootModules = nub [moduleName manifest.schemaType,moduleName manifest.schemaMetadata]
  (rootSources,_) <- inspectExports libdir roots packages [moduleName manifest.schemaType]
  -- This prepass cannot see generated bindings: Root determines their types.
  writeFile (generated </> "KyynGuestSchemaEntry.hs") (unlines
    (["{-# LANGUAGE TypeApplications #-}","module KyynGuestSchemaEntry where",
      "import Kyyn.Contract", "import qualified Data.Aeson as Json",
      "import qualified Data.ByteString.Lazy as Bytes"] ++
     map ("import qualified " ++) rootModules ++
     ["main :: IO ()", "main = case compileContract (contract @" ++ name manifest.schemaType ++ ") of",
      "  Left problem -> fail (show problem)",
      "  Right _ -> Bytes.writeFile \".kyyn-generated/metadata.json\" (Json.encode " ++ name manifest.schemaMetadata ++ ")"]))
  compile compiler generated "schema" (packages ++ ["-isrc"]) (generated </> "KyynGuestSchemaEntry.hs") (generated </> "schema-entry")
  callProcess ("./" ++ generated </> "schema-entry") []
  metadata <- Bytes.readFile (generated </> "metadata.json") >>= either fail pure . eitherDecodeStrict'
  generatedBindings <- either fail pure (bindings manifest metadata)
  writeFile (generated </> "KyynQueryBindings.hs") generatedBindings
  pure rootSources

finishGuest :: FilePath -> FilePath -> [String] -> FilePath -> IO ()
finishGuest compiler generated packages destination = do
  -- Runtime is a public sublibrary, deliberately absent from the author SDK.
  let packageTool = takeDirectory compiler </> "ghc-pkg"
  runtime <- readProcess packageTool ["field","z-kyyn-sdk-z-runtime","id","--simple-output"] "" >>= singleLine "runtime package"
  compile compiler generated "guest" (packages ++ ["-isrc", "-i" ++ generated,"-package-id",runtime])
    (generated </> "KyynGuestEntry.hs") destination
  callProcess destination ["--check-build"]

compile :: FilePath -> FilePath -> String -> [String] -> FilePath -> FilePath -> IO ()
compile compiler generated stage options entry output = do
  let objects = generated </> stage
  createDirectoryIfMissing True objects
  callProcess compiler (["--make","-XGHC2021","-odir",objects,"-hidir",objects] ++ options ++ ["-main-is",takeBaseName entry ++ ".main",entry,"-o",output])

singleLine :: String -> String -> IO String
singleLine label output = case lines output of
  [value] | not (null value) -> pure value
  _ -> fail ("Expected one " ++ label)

bindings :: Manifest -> SchemaMetadata -> Either String String
bindings manifest (SchemaMetadata _ _ collections) = do
  unless (all (validField . (\(CollectionDecl _ field _) -> field)) collections)
    (Left "Collection metadata must name a Haskell record field")
  pure (unlines
    (["{-# LANGUAGE DataKinds, TypeApplications, OverloadedStrings #-}",
      "{-# OPTIONS_GHC -Wno-missing-signatures #-}",
      "module KyynQueryBindings where", "import GHC.Records (getField)",
      "import qualified Kyyn.Types.Query as Query",
      "import qualified " ++ Text.unpack (referenceModule manifest.schemaType),
      "type Query a = Query.Query " ++ Text.unpack (referenceName manifest.schemaType) ++ " a"] ++
     [Text.unpack field ++ " = Query.CollectionBinding " ++ show (Text.unpack collection) ++
      " (\\root -> getField @" ++ show (Text.unpack field) ++ " (root :: " ++ Text.unpack (referenceName manifest.schemaType) ++ "))"
         | CollectionDecl collection field _ <- collections]))
  where
    validField field = case Text.uncons field of
      Just (first,rest) -> (isLower first || first == '_') &&
        Text.all (\c -> isAlphaNum c || c == '_' || c == '\'') rest
      Nothing -> False

showExports :: [ModuleDescription] -> String
showExports modules = "[" ++ intercalate "," (map selected modules) ++ "]"
  where
    quoted = show . Text.unpack
    optional = maybe "Nothing" (\value -> "(Just " ++ quoted value ++ ")")
    selected m = "ModuleDescription " ++ unwords
      [quoted m.moduleName,quoted m.moduleSource,optional m.moduleDocumentation,
       show (map Text.unpack m.moduleInstances),"[" ++ intercalate "," (map exported m.moduleExports) ++ "]"]
    exported e = "ExportDescription " ++ unwords
      [quoted e.exportName,quoted e.exportSignature,quoted e.exportOrigin,optional e.exportDocumentation,show e.exportKind]
