{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Build.Driver (buildGuest) where

import Control.Monad (unless, forM, when)
import Data.Aeson (eitherDecodeStrict', encode)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.Char (isAlphaNum, isLower)
import Data.List (nub, intercalate)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import System.Directory (createDirectoryIfMissing, doesFileExist, doesPathExist, makeAbsolute, withCurrentDirectory)
import System.FilePath ((</>), takeDirectory, takeBaseName)
import System.Process (callProcess, readProcess)
import qualified Kyyn.Build.Sources as Sources
import Kyyn.Build.Inspection
import Kyyn.Build.RecipeBindings (writeRecipeBindings, writeEvolutionBindings)
import Kyyn.Build.OutputBindings (writeOutputBindings)
import Kyyn.Build.ToolBindings (writeToolBindings)
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
    basePackages <- packageOptions libdir
    roots <- ("src" :) <$> installedPluginRoots
    let packages = basePackages ++ map ("-i" ++) roots
        generated = ".kyyn-generated"
    occupied <- or <$> traverse doesFileExist
      [root </> moduleName ++ extension | root <- roots, moduleName <- ["KyynQueryBindings","KyynGuestSchemaRoot","KyynGuestSchemaBefore","KyynGuestSchemaAfter","KyynGuestSchemaEntry","KyynGuestEntry","KyynGuestRegistrations"],
        extension <- [".hs",".lhs"]]
    unless (not occupied) (fail "Authored source collides with a generated guest module")
    existing <- doesPathExist generated
    unless (not existing) (fail "Guest build requires a fresh .kyyn-generated directory")
    createDirectoryIfMissing True generated
    case selection of
      DiscoveryEntries (ModuleExports modules) -> do
        let selectedModules = map Text.unpack modules
        needs <- requiredBindings libdir roots packages selectedModules
        when needs.toolBindings $ do
          (_,_,_,registrations) <- preparePlugins compiler libdir generated basePackages
          writeToolBindings generated roots registrations
        when needs.rootBindings $ do
          manifest <- Text.readFile "kb.dhall" >>= either fail pure . parseManifest
          _ <- prepareRoot compiler libdir generated packages roots manifest
          pure ()
        (_,exports) <- inspectExports libdir (roots ++ [generated]) packages selectedModules
        writeGuest generated exports [] []
        finishGuest compiler generated packages destination
      PluginEntries -> do
        (_,pluginPackages,entries,_) <- preparePlugins compiler libdir generated basePackages
        let modules = nub (map (Text.unpack . referenceModule) (concatMap fst entries))
        (_,exports) <- inspectExports libdir (roots ++ [generated]) pluginPackages modules
        writeGuest generated exports modules (map snd entries)
        finishGuest compiler generated pluginPackages destination
      RootEntries -> buildRoot compiler libdir generated basePackages destination selection
      DiscoveryEntries RootSchema -> buildRoot compiler libdir generated basePackages destination selection
      RecipeEntries references -> buildRecipes compiler libdir generated basePackages destination references
      EvolutionEntries details -> buildEvolution compiler libdir generated basePackages destination details

preparePlugins :: FilePath -> FilePath -> FilePath -> [String]
  -> IO ([FilePath],[String],[([Reference],String)],[RegisteredPlugin])
preparePlugins compiler libdir generated basePackages = do
  plugins <- discoverPlugins
  let roots = "src" : map sourceRoot plugins
      packages = basePackages ++ map ("-i" ++) roots
  registrations <- bootstrapPlugins (\pluginRoots -> compile compiler generated "registrations" (basePackages ++ map ("-i" ++) pluginRoots)) generated plugins
  entries <- forM [(plugin,connector) | RegisteredPlugin plugin connectors <- registrations, connector <- connectors] $ \(plugin,connector) -> do
    let identity = "(ConnectorIdentity " ++ show plugin.pluginName ++ " " ++ show connector.name ++ ")"
        adapter role factory reference = do
          implementation <- either fail pure (qualifiedReference False reference)
          (sources,_) <- inspectExports libdir (roots ++ [generated]) packages [Text.unpack (referenceModule implementation)]
          let name = "$" <> role <> "." <> plugin.pluginName <> "." <> connector.name
          pure ([implementation],"(" ++ factory ++ " " ++ show name ++ " " ++ show sources ++ " " ++ Text.unpack reference ++ ")")
    (configReferences,config) <- adapter "configuration" "configurationEntry" connector.validateConfig
    case connector of
      P.SourceConnector _ fetch _ methods login -> do
        (fetchReferences,acquire) <- adapter "acquisition" "acquisitionEntry" fetch
        authentication <- traverse (adapter "login" "loginEntry") login
        captured <- forM methods $ \method -> do
          implementation <- either fail pure (qualifiedReference False method.implementation)
          (sources,_) <- inspectExports libdir (roots ++ [generated]) packages [Text.unpack (referenceModule implementation)]
          let name = Text.intercalate "." [plugin.pluginName,connector.name,method.methodName]
              methodIdentity = "(CapturedMethodIdentity " ++ unwords (map show
                [plugin.pluginName,connector.name,method.methodName,method.methodDescription]) ++ ")"
          pure ([implementation],"capturedReadEntry " ++ show name ++ " " ++ methodIdentity ++ " " ++ show sources ++ " " ++ Text.unpack method.implementation)
        pure (configReferences ++ fetchReferences ++ maybe [] fst authentication ++ concatMap fst captured,
          "sourceConnectorEntry " ++ identity ++ " " ++ config ++ " " ++ acquire ++ " " ++
          maybe "Nothing" (\(_,entry) -> "(Just " ++ entry ++ ")") authentication ++ " [" ++ intercalate "," (map snd captured) ++ "]")
      P.SinkConnector _ _ publish defaults -> do
        (publishReferences,publication) <- adapter "sink" "sinkEntry" publish
        (defaultReferences,options) <- adapter "sinkDefaults" "sinkDefaultsEntry" defaults
        pure (configReferences ++ publishReferences ++ defaultReferences,
          "sinkConnectorEntry " ++ identity ++ " " ++ config ++ " " ++ publication ++ " " ++ options)
  pure (roots,packages,entries,registrations)

buildRoot :: FilePath -> FilePath -> FilePath -> [String] -> FilePath -> GuestSelection -> IO ()
buildRoot compiler libdir generated basePackages destination selection = do
  roots <- ("src" :) <$> installedPluginRoots
  let packages = basePackages ++ map ("-i" ++) roots
  (pluginEntries,registrations) <- if selection == RootEntries
    then do
      (_,_,entries,registrations) <- preparePlugins compiler libdir generated basePackages
      writeToolBindings generated roots registrations
      pure (entries,registrations)
    else pure ([],[])
  manifest <- Text.readFile "kb.dhall" >>= either fail pure . parseManifest
  outputModules <- if selection == RootEntries then writeOutputBindings generated roots registrations manifest else pure []
  let name = Text.unpack . referenceName
      moduleName = Text.unpack . referenceModule
      rootModules = nub [moduleName manifest.schemaType,moduleName manifest.schemaMetadata]
      selectedQueries = if selection == RootEntries then manifest.queries else []
      selectedTools = if selection == RootEntries then manifest.tools else []
  rootSources <- prepareRoot compiler libdir generated packages roots manifest
  let selectedModules = nub (outputModules ++ rootModules ++ [moduleName manifest.validator | selection == RootEntries] ++ concat
        [[moduleName q.queryImplementation,moduleName q.inputType,moduleName q.inputMetadata,
          moduleName q.resultType,moduleName q.resultMetadata] | q <- selectedQueries] ++
        concat [[moduleName implementation,moduleName input,moduleName result] | Tool _ _ implementation input result <- selectedTools] ++
        map moduleName (concatMap fst pluginEntries))
  (_,exports) <- inspectExports libdir (roots ++ [generated]) packages selectedModules
  querySources <- forM selectedQueries $ \q -> do
    (arguments,_) <- inspectExports libdir (roots ++ [generated]) packages [moduleName q.inputType]
    (results,_) <- inspectExports libdir (roots ++ [generated]) packages [moduleName q.resultType]
    pure (q,arguments,results)
  toolEntries <- forM selectedTools $ \(Tool selectedName description implementation input result) -> do
    (inputSources,_) <- inspectExports libdir (roots ++ [generated]) packages [moduleName input]
    (resultSources,_) <- inspectExports libdir (roots ++ [generated]) packages [moduleName result]
    pure ("toolEntry @" ++ name input ++ " @" ++ name result ++ " " ++ show selectedName ++ " " ++ show description ++
      " " ++ show inputSources ++ " " ++ show resultSources ++ " KyynGuestDispatch.dispatch " ++ name implementation)
  let rootEntry = if selection == RootEntries
        then "validationEntry @" ++ name manifest.schemaType ++ " " ++ name manifest.schemaMetadata ++ " " ++ show rootSources ++ " " ++ name manifest.validator
        else "describeEntry @" ++ name manifest.schemaType ++ " \"root\" " ++ name manifest.schemaMetadata ++ " " ++ show rootSources
  writeGuest generated exports (selectedModules ++ ["KyynGuestDispatch" | not (null selectedTools)]) (rootEntry : map snd pluginEntries ++ toolEntries ++
         ["queryEntry @" ++ name manifest.schemaType ++ " @" ++ name q.inputType ++ " @" ++ name q.resultType ++
          " " ++ show (Text.unpack q.queryName) ++
          " (" ++ name manifest.schemaMetadata ++ "," ++ show rootSources ++ ")" ++
          " (" ++ name q.inputMetadata ++ "," ++ show arguments ++ ")" ++
          " (" ++ name q.resultMetadata ++ "," ++ show results ++ ") " ++ name q.queryImplementation
            | (q,arguments,results) <- querySources])
  finishGuest compiler generated packages destination

buildRecipes :: FilePath -> FilePath -> FilePath -> [String] -> FilePath -> [RecipeReference] -> IO ()
buildRecipes compiler libdir generated basePackages destination references = do
  runtime <- runtimeOptions compiler
  (roots,packages,plugins,registrations) <- preparePlugins compiler libdir generated (basePackages ++ runtime)
  writeToolBindings generated roots registrations
  manifest <- Text.readFile "kb.dhall" >>= either fail pure . parseManifest
  rootSources <- prepareRoot compiler libdir generated packages roots manifest
  metadata <- Bytes.readFile (generated </> "metadata.json") >>= either fail pure . eitherDecodeStrict'
  writeRecipeBindings generated roots manifest metadata
  entries <- forM references $ \reference -> case reference of
    OpenState "()" -> pure ([],"describeEntry @() \"$state.()\" (SchemaMetadata [] [] []) []")
    OpenState name -> do
      selected <- either (fail . (("Recipe state " ++ Text.unpack name ++ ": ") ++)) pure (qualifiedReference True name)
      (sources,_) <- inspectExports libdir (roots ++ [generated]) packages [Text.unpack (referenceModule selected)]
      pure ([Text.unpack (referenceModule selected)],"describeEntry @" ++ Text.unpack name ++ " " ++ show ("$state." <> name) ++
        " (SchemaMetadata [] [] []) " ++ show sources)
    ClosedFlow name -> do
      selected <- either (fail . (("Recipe flow " ++ Text.unpack name ++ ": ") ++)) pure (qualifiedReference False name)
      (sources,_) <- inspectExports libdir (roots ++ [generated]) packages [Text.unpack (referenceModule selected)]
      let render format = "Agentic.Describe." ++ format ++ " (Agentic.Describe.describe " ++ Text.unpack name ++ ")"
      pure ([Text.unpack (referenceModule selected)],"recipeEntry @" ++ Text.unpack (referenceName manifest.schemaType) ++
        " " ++ show name ++ " (" ++ Text.unpack (referenceName manifest.schemaMetadata) ++ "," ++ show rootSources ++ ") " ++ show sources ++
        " KyynFactEditCodec.rootCodec KyynGuestDispatch.dispatch (Kyyn.Agentic.interpret " ++ Text.unpack name ++ ") " ++
        "(\\format -> case format of Tree -> " ++ render "renderTree" ++ "; Dot -> " ++ render "dot" ++ "; Mermaid -> " ++ render "mermaid" ++ ")")
  let modules = nub (map (Text.unpack . referenceModule) (manifest.schemaType : manifest.schemaMetadata : concatMap fst plugins)
        ++ concatMap fst entries ++ ["KyynFactEditCodec","KyynGuestDispatch","Kyyn.Agentic","Agentic.Describe"])
  (_,exports) <- inspectExports libdir (roots ++ [generated]) packages modules
  let rootEntry = "describeEntry @" ++ Text.unpack (referenceName manifest.schemaType) ++ " \"root\" " ++
        Text.unpack (referenceName manifest.schemaMetadata) ++ " " ++ show rootSources
  writeGuest generated exports modules (rootEntry : map snd plugins ++ map snd entries)
  finishGuest compiler generated packages destination

buildEvolution :: FilePath -> FilePath -> FilePath -> [String] -> FilePath -> EvolutionSelection -> IO ()
buildEvolution compiler libdir generated basePackages destination (EvolutionSelection beforeType beforeAnnotations recipe discovery) = do
  when (recipe /= Nothing) (fail "Recipe evolution bindings are not implemented yet")
  before <- either fail pure (qualifiedReference True beforeType)
  beforeMetadata <- either fail pure (qualifiedReference False beforeAnnotations)
  manifest <- Text.readFile "kb.dhall" >>= either fail pure . parseManifest
  pluginRoots <- installedPluginRoots
  runtime <- runtimeOptions compiler
  let beforeRoots = ".kyyn-before" : pluginRoots
      afterRoots = "src" : pluginRoots
      packages roots = basePackages ++ runtime ++ map ("-i" ++) roots
  (beforeSources,oldMetadata) <- inspectRoot compiler libdir generated "Before" (packages beforeRoots) beforeRoots before beforeMetadata
  (afterSources,newMetadata) <- inspectRoot compiler libdir generated "After" (packages afterRoots) afterRoots manifest.schemaType manifest.schemaMetadata
  authored <- concat <$> traverse Sources.sourceFiles afterRoots
  changes <- Sources.sourceFiles ".kyyn-change"
  let merged = generated </> "sources"
  origins <- Sources.mergeSources libdir merged (beforeSources ++ authored ++ changes)
  let roots = [merged]
      selectedPackages = packages roots
  writeEvolutionBindings generated roots (before,oldMetadata) (manifest.schemaType,newMetadata)
  queryBindings <- either fail pure (bindings manifest newMetadata)
  writeFile (generated </> "KyynQueryBindings.hs") queryBindings
  let defaults = ["Kyyn.Workspace.Evolution","Kyyn.Workspace.Before","Kyyn.Workspace.After","Kyyn.Workspace.FactEdits"]
      modules = case discovery of
        Nothing -> "Evolution" : defaults
        Just [] -> defaults
        Just selected -> map Text.unpack selected
      name = Text.unpack . referenceName
      oldDescription = "(" ++ show oldMetadata ++ "," ++ show beforeSources ++ ")"
      newDescription = "(" ++ show newMetadata ++ "," ++ show afterSources ++ ")"
      entries = case discovery of
        Nothing -> ["evolutionEntry @" ++ name before ++ " @" ++ name manifest.schemaType ++ " " ++
          oldDescription ++ " " ++ newDescription ++ " Evolution.evolution"]
        Just _ -> ["describeEntry @" ++ name before ++ " \"$before\" (" ++ show oldMetadata ++ ") " ++ show beforeSources,
                   "describeEntry @" ++ name manifest.schemaType ++ " \"$after\" (" ++ show newMetadata ++ ") " ++ show afterSources]
  (_,exports) <- inspectExports libdir (roots ++ [generated]) selectedPackages modules
  let original path = maybe path Text.pack (lookup (Text.unpack path) origins)
      located = [entry { moduleSource = original entry.moduleSource } | entry <- exports]
  writeGuest generated located (nub (modules ++ map (Text.unpack . referenceModule) [before,manifest.schemaType])) entries
  finishGuest compiler generated selectedPackages destination

writeGuest :: FilePath -> [ModuleDescription] -> [String] -> [String] -> IO ()
writeGuest generated exports modules entries =
  writeFile (generated </> "KyynGuestEntry.hs") (unlines
    (["{-# LANGUAGE TypeApplications, OverloadedStrings #-}","module KyynGuestEntry where",
      "import Kyyn.Runtime.Guest", "import Kyyn.Types.Guest", "import Kyyn.Types.SchemaMetadata", "import Kyyn.Contract (ProjectionError)",
      "import System.Environment (getArgs)"] ++ map ("import qualified " ++) modules ++
     ["main :: IO ()", "main = do", "  arguments <- getArgs", "  case arguments of",
      "    [\"--check-build\"] -> checkEntries selected",
      "    [] -> runGuest " ++ showExports exports ++ " selected",
      "    _ -> fail \"Unexpected guest arguments\"",
      "selected :: [Either ProjectionError Entry]", "selected = [" ++ intercalate ",\n  " entries ++ "]"]))

prepareRoot :: FilePath -> FilePath -> FilePath -> [String] -> [FilePath] -> Manifest -> IO [FilePath]
prepareRoot compiler libdir generated packages roots manifest = do
  (sources,metadata) <- inspectRoot compiler libdir generated "Root" packages roots manifest.schemaType manifest.schemaMetadata
  generatedBindings <- either fail pure (bindings manifest metadata)
  writeFile (generated </> "KyynQueryBindings.hs") generatedBindings
  -- Also consumed by generated edit bindings in recipe builds.
  Bytes.writeFile (generated </> "metadata.json") (Lazy.toStrict (encode metadata))
  pure sources

-- The metadata prepass is independent for each endpoint. Its dependency-only
-- modules need not coexist with the migration's Before/After schema closures.
inspectRoot :: FilePath -> FilePath -> FilePath -> String -> [String] -> [FilePath]
  -> Reference -> Reference -> IO ([FilePath],SchemaMetadata)
inspectRoot compiler libdir generated stage packages roots schema annotations = do
  let name = Text.unpack . referenceName
      moduleName = Text.unpack . referenceModule
      rootModules = nub [moduleName schema,moduleName annotations]
      entryName = "KyynGuestSchema" ++ stage
      metadataPath = generated </> stage ++ "-metadata.json"
      executable = generated </> stage ++ "-schema"
      entry = generated </> entryName ++ ".hs"
  (rootSources,_) <- inspectExports libdir roots packages [moduleName schema]
  writeFile entry (unlines
    (["{-# LANGUAGE TypeApplications #-}","module " ++ entryName ++ " where",
      "import Kyyn.Contract", "import qualified Data.Aeson as Json",
      "import qualified Data.ByteString.Lazy as Bytes"] ++
     map ("import qualified " ++) rootModules ++
     ["main :: IO ()", "main = case compileContract (contract @" ++ name schema ++ ") of",
      "  Left problem -> fail (show problem)",
      "  Right _ -> Bytes.writeFile " ++ show metadataPath ++ " (Json.encode " ++ name annotations ++ ")"]))
  compile compiler generated (stage ++ "-schema-objects") packages entry executable
  callProcess ("./" ++ executable) []
  metadata <- Bytes.readFile metadataPath >>= either fail pure . eitherDecodeStrict'
  pure (rootSources,metadata)

finishGuest :: FilePath -> FilePath -> [String] -> FilePath -> IO ()
finishGuest compiler generated packages destination = do
  -- Runtime is a public sublibrary, deliberately absent from the author SDK.
  runtime <- runtimeOptions compiler
  compile compiler generated "guest" (packages ++ ["-isrc", "-i" ++ generated] ++ runtime)
    (generated </> "KyynGuestEntry.hs") destination
  callProcess destination ["--check-build"]

runtimeOptions :: FilePath -> IO [String]
runtimeOptions compiler = do
  let packageTool = takeDirectory compiler </> "ghc-pkg"
  runtime <- readProcess packageTool ["field","z-kyyn-sdk-z-runtime","id","--simple-output"] "" >>= singleLine "runtime package"
  pure ["-package-id",runtime]

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
