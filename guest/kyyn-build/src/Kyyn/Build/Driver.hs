{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Build.Driver (buildGuest) where

import Control.Monad (unless, forM, when)
import Data.Aeson (eitherDecodeStrict', encode)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.Char (isAlphaNum, isLower)
import Data.List (nub, intercalate, isPrefixOf, sortOn)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import System.Directory (createDirectoryIfMissing, doesFileExist, doesPathExist, makeAbsolute, withCurrentDirectory)
import System.FilePath ((</>), takeDirectory, takeBaseName)
import System.Process (callProcess, readProcess)
import qualified Kyyn.Build.Sources as Sources
import Kyyn.Build.Inspection
import Kyyn.Build.FrozenProposal (writeFrozenProposal)
import Kyyn.Build.RecipeHandles (handleImports, handleImportsWithStored, handleModules, writeRecipeHandles)
import Kyyn.Build.RecipeBindings (writeRecipeBindings, writeEvolutionBindings, writeRecipeEvolutionBindings, writeTargetEvolutionBindings)
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
    let generated = ".kyyn-generated"
    occupied <- or <$> traverse doesFileExist
      [root </> moduleName ++ extension | root <- roots, moduleName <- ["KyynQueryBindings","KyynGuestSchemaRoot","KyynGuestSchemaBefore","KyynGuestSchemaAfter","KyynGuestSchemaEntry","KyynGuestEntry","KyynGuestRegistrations"],
        extension <- [".hs",".lhs"]]
    unless (not occupied) (fail "Authored source collides with a generated guest module")
    existing <- doesPathExist generated
    unless (not existing) (fail "Guest build requires a fresh .kyyn-generated directory")
    createDirectoryIfMissing True generated
    case selection of
      DiscoveryEntries (ModuleExports modules) ->
        buildModules compiler libdir generated basePackages destination (map Text.unpack modules)
      PluginEntries -> do
        (_,pluginPackages,entries,_) <- preparePlugins compiler libdir generated basePackages
        let modules = nub (map (Text.unpack . referenceModule) (concatMap fst entries))
        (_,exports) <- inspectExports libdir (roots ++ [generated]) pluginPackages modules
        writeGuest generated exports modules (map snd entries)
        finishGuest compiler generated pluginPackages destination
      RootEntries -> buildRoot compiler libdir generated basePackages destination selection
      DiscoveryEntries (RootApi selected) -> buildRootApi compiler libdir generated basePackages destination selected
      DiscoveryEntries RootSchema -> buildRoot compiler libdir generated basePackages destination selection
      RecipeEntries references -> buildRecipes compiler libdir generated basePackages destination references
      TargetEvolutionEntries references modules -> buildTargetEvolution compiler libdir generated basePackages destination references modules
      EvolutionEntries details -> buildEvolution compiler libdir generated basePackages destination details

-- Resolve symbols against compiler module headers and the locked package set.
-- Generated workspace handles are namespaced by their imported type/module.
resolveModules :: FilePath -> [FilePath] -> [String] -> IO [String]
resolveModules libdir roots requested = do
  let prefixes value = [intercalate "." (take count parts) | count <- [1 .. length parts]]
        where parts = map Text.unpack (Text.splitOn "." (Text.pack value))
  authored <- fmap concat $ forM (nub (concatMap prefixes requested)) $ \name ->
    fmap concat $ forM roots $ \root -> do
      let path = root </> map (\c -> if c == '.' then '/' else c) name ++ ".hs"
      present <- doesFileExist path
      if present then pure . pure . fst =<< Sources.moduleHeader libdir path else pure []
  libraries <- packageModuleNames libdir
  let fixed = ["KyynQueryBindings","Kyyn.Connectors","Kyyn.Agentic","KyynFrozenProposal",
        "Kyyn.Workspace.Before","Kyyn.Workspace.After","Kyyn.Workspace.Target","Kyyn.Workspace.Target.Fields","Kyyn.Workspace.Evolution","Kyyn.Workspace.FactEdits"]
      candidates = authored ++ libraries ++ fixed
      choose value = case sortOn (negate . length)
        [name | name <- candidates, name == value || (name ++ ".") `isPrefixOf` value] of
        name:_ | not (any (`isPrefixOf` value) ["Kyyn.Plugins.","Kyyn.Workspace.Before.RecipeTypes.","Kyyn.Workspace.After.RecipeTypes.","Kyyn.Workspace.After.RecipeFlows.","Kyyn.Workspace.Target.RecipeTypes.","Kyyn.Workspace.Target.RecipeFlows."]) -> name
        _ -> intercalate "." (takeWhile (\part -> case part of first:_ -> not (isLower first); [] -> False) (map Text.unpack (Text.splitOn "." (Text.pack value))))
  pure (nub (map choose requested))

buildModules :: FilePath -> FilePath -> FilePath -> [String] -> FilePath -> [String] -> IO ()
buildModules compiler libdir generated basePackages destination requested = do
  roots <- ("src" :) <$> installedPluginRoots
  runtime <- runtimeOptions compiler
  let packages = basePackages ++ runtime ++ map ("-i" ++) roots
  selected <- resolveModules libdir roots requested
  needs <- requiredBindings libdir roots packages selected
  when needs.toolBindings $ do
    (_,_,_,registrations) <- preparePlugins compiler libdir generated basePackages
    writeToolBindings generated roots registrations
  when (needs.rootBindings || needs.workspaceBindings) $ do
    manifest <- Text.readFile "kb.dhall" >>= either fail pure . parseManifest
    _ <- prepareRoot compiler libdir generated packages roots manifest
    when needs.workspaceBindings $ do
      metadata <- Bytes.readFile (generated </> "metadata.json") >>= either fail pure . eitherDecodeStrict'
      writeRecipeBindings generated roots manifest metadata
  (_,exports) <- inspectExports libdir (roots ++ [generated]) packages selected
  writeGuest generated exports [] []
  finishGuest compiler generated packages destination

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
  -- All selected exports are checked above. Only their individual source
  -- closures are needed here; re-typechecking each input/result repeats work.
  querySources <- forM selectedQueries $ \q -> do
    arguments <- sourceDependencies libdir (roots ++ [generated]) packages [moduleName q.inputType]
    results <- sourceDependencies libdir (roots ++ [generated]) packages [moduleName q.resultType]
    pure (q,arguments,results)
  toolEntries <- forM selectedTools $ \(Tool selectedName description implementation input result) -> do
    inputSources <- sourceDependencies libdir (roots ++ [generated]) packages [moduleName input]
    resultSources <- sourceDependencies libdir (roots ++ [generated]) packages [moduleName result]
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

-- Inventory names come from compiler-parsed headers, not file-name guesses.
-- Listing loads generated public bindings, leaving unfinished authored bodies
-- alone until the caller explicitly selects their module or symbol.
buildRootApi :: FilePath -> FilePath -> FilePath -> [String] -> FilePath -> Maybe Text.Text -> IO ()
buildRootApi compiler libdir generated basePackages destination (Just selected) =
  buildModules compiler libdir generated basePackages destination [Text.unpack selected]
buildRootApi compiler libdir generated basePackages destination Nothing = do
  runtime <- runtimeOptions compiler
  (roots,packages,_,registrations) <- preparePlugins compiler libdir generated (basePackages ++ runtime)
  writeToolBindings generated roots registrations
  manifest <- Text.readFile "kb.dhall" >>= either fail pure . parseManifest
  _ <- prepareRoot compiler libdir generated packages roots manifest
  metadata <- Bytes.readFile (generated </> "metadata.json") >>= either fail pure . eitherDecodeStrict'
  writeRecipeBindings generated roots manifest metadata
  authored <- concat <$> traverse Sources.sourceFiles roots
  emitted <- Sources.sourceFiles generated
  let public name = name `elem` ["KyynQueryBindings","Kyyn.Connectors","Kyyn.Agentic"] ||
        any (`isPrefixOf` name) ["Kyyn.Workspace.","Kyyn.Plugins."]
  inventory <- forM (authored ++ emitted) $ \path -> do
    (name,_) <- Sources.moduleHeader libdir path
    pure (name,path)
  libraries <- packageModuleNames libdir
  let sdk name = ("Agentic" `isPrefixOf` name || "Kyyn." `isPrefixOf` name) &&
        not (any (`isPrefixOf` name) ["Kyyn.Build", "Kyyn.Runtime", "Kyyn.Types"]) &&
        not (".Internal" `Text.isSuffixOf` Text.pack name)
      names = [(name,path) | (name,path) <- inventory, path `elem` authored || public name] ++
        [(name,"") | name <- libraries, sdk name]
      requested = [name | (name,path) <- names, path `elem` emitted]
  (_,inspected) <- inspectExports libdir (roots ++ [generated]) packages requested
  let described name path = case [entry | entry <- inspected, entry.moduleName == Text.pack name] of
        [entry] -> entry
        _ -> ModuleDescription (Text.pack name) (Text.pack path) Nothing [] []
  writeGuest generated [described name path | (name,path) <- names] [] []
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
buildEvolution compiler libdir generated basePackages destination (EvolutionSelection before annotations references recipe (Just requested))
  | not (null requested) = do
      roots <- ("src" :) <$> installedPluginRoots
      selected <- resolveModules libdir roots (map Text.unpack requested)
      needs <- requiredBindings libdir roots (basePackages ++ map ("-i" ++) roots) selected
      if needs.workspaceBindings then
        buildEvolutionFull compiler libdir generated basePackages destination
          (EvolutionSelection before annotations references recipe (Just (map Text.pack selected)))
      else buildModules compiler libdir generated basePackages destination selected
buildEvolution compiler libdir generated basePackages destination details =
  buildEvolutionFull compiler libdir generated basePackages destination details

buildEvolutionFull :: FilePath -> FilePath -> FilePath -> [String] -> FilePath -> EvolutionSelection -> IO ()
buildEvolutionFull compiler libdir generated basePackages destination (EvolutionSelection beforeType beforeAnnotations references recipe discovery) = do
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
  -- Generated type dependencies are available while GHC selects Before state
  -- closures. Only loaded Before source is copied into the migration namespace.
  authored <- concat <$> traverse Sources.sourceFiles afterRoots
  changes <- Sources.sourceFiles ".kyyn-change"
  imports <- concatMap snd <$> traverse (Sources.moduleHeader libdir) (authored ++ changes)
  let handles = handleImports (imports ++ maybe [] (map Text.unpack) discovery)
  importedModules <- either fail pure (handleModules handles)
  let inspectionRoots = beforeRoots ++ afterRoots ++ [generated]
  writeEvolutionBindings generated (beforeRoots ++ afterRoots) (before,oldMetadata) (manifest.schemaType,newMetadata)
  queryBindings <- either fail pure (bindings manifest newMetadata)
  writeFile (generated </> "KyynQueryBindings.hs") queryBindings
  stateModules <- fmap concat $ forM references $ \reference -> case reference of
    OpenState "()" -> pure []
    OpenState selected -> pure . pure . Text.unpack . referenceModule =<< either fail pure (qualifiedReference True selected)
    ClosedFlow selected -> pure . pure . Text.unpack . referenceModule =<< either fail pure (qualifiedReference False selected)
  needs <- requiredBindings libdir inspectionRoots (packages inspectionRoots) (stateModules ++ importedModules)
  when needs.toolBindings $ do
    (_,_,_,registrations) <- preparePlugins compiler libdir generated (basePackages ++ runtime)
    writeToolBindings generated (beforeRoots ++ afterRoots) registrations
  (importedSources,importedBindings,importedEntries,_) <- writeRecipeHandles libdir generated
    (packages inspectionRoots) beforeRoots afterRoots manifest.schemaType handles
  states <- forM (zip [0 :: Int ..] references) $ \(index,reference) -> case reference of
    OpenState "()" -> pure ([],[],"describeState @() []")
    OpenState selected -> do
      state <- either fail pure (qualifiedReference True selected)
      (closure,_) <- inspectExports libdir inspectionRoots (packages inspectionRoots) [Text.unpack (referenceModule state)]
      pure (closure,[Text.unpack (referenceModule state)],"describeState @" ++ Text.unpack selected ++ " " ++ show closure)
    ClosedFlow selected -> do
      flow <- either fail pure (qualifiedReference False selected)
      (closure,_) <- inspectExports libdir inspectionRoots (packages inspectionRoots) [Text.unpack (referenceModule flow)]
      let moduleName = "KyynBeforeState" ++ show index
      writeFile (generated </> moduleName ++ ".hs") (unlines
        ["{-# LANGUAGE TemplateHaskell #-}","module " ++ moduleName ++ " where",
         "import Language.Haskell.TH (mkName)","import Kyyn.Build.RecipeTypes (flowStateAlias)",
         "import qualified Kyyn.Recipe as Recipe", "import qualified " ++ Text.unpack (referenceModule before),
         "import qualified " ++ Text.unpack (referenceModule flow),
         "$(flowStateAlias (mkName \"State\") ''" ++ Text.unpack beforeType ++ " '" ++ Text.unpack selected ++ ")"])
      pure (closure,[moduleName],"describeState @" ++ moduleName ++ ".State " ++ show closure)
  selectedState <- case recipe of
    Nothing -> pure Nothing
    Just reference -> case [(index,closure,names) | (index,(actual,(closure,names,_))) <- zip [0 :: Int ..] (zip references states), actual == reference] of
      [(index,closure,names)] -> do
        let state = case reference of OpenState name -> Text.unpack name; ClosedFlow _ -> "KyynBeforeState" ++ show index ++ ".State"
        writeRecipeEvolutionBindings generated before oldMetadata state names
        pure (Just (state,closure))
      _ -> fail "Selected recipe must have exactly one Before state descriptor"
  hasProposal <- doesFileExist ".kyyn-change/proposal.dhall"
  hasLowered <- doesFileExist ".kyyn-change/KyynFrozenProposal.json"
  let frozen = case (selectedState,discovery) of
        (Just _,Just _) -> hasProposal
        (Just _,Nothing) -> hasLowered
        _ -> False
  when frozen $ do
    occupied <- or <$> traverse doesFileExist
      [root </> "KyynFrozenProposal" ++ extension | root <- beforeRoots ++ afterRoots ++ [".kyyn-change"], extension <- [".hs",".lhs"]]
    when occupied (fail "Authored source collides with generated module KyynFrozenProposal")
    proposal <- case discovery of
      Just _ -> pure Nothing
      Nothing -> Just <$> (Bytes.readFile ".kyyn-change/KyynFrozenProposal.json" >>= either fail pure . eitherDecodeStrict')
    writeFrozenProposal generated proposal
  let merged = generated </> "sources"
      oldStateSources = [path | (closure,_,_) <- states, path <- closure, ".kyyn-before/" `isPrefixOf` path]
  origins <- Sources.mergeSources libdir merged (beforeSources ++ oldStateSources ++ filter (isPrefixOf ".kyyn-before/") importedSources ++ authored ++ changes)
  let roots = [merged]
      selectedPackages = packages roots
  let defaults = ["Kyyn.Workspace.Evolution","Kyyn.Workspace.Before","Kyyn.Workspace.After","Kyyn.Workspace.FactEdits"] ++ ["KyynFrozenProposal" | frozen]
      selectedModules = case discovery of
        Nothing -> "Evolution" : defaults
        Just [] -> defaults
        Just selected -> map Text.unpack selected
      name = Text.unpack . referenceName
      oldDescription = "(" ++ show oldMetadata ++ "," ++ show beforeSources ++ ")"
      newDescription = "(" ++ show newMetadata ++ "," ++ show afterSources ++ ")"
      entries = case discovery of
        Nothing -> case selectedState of
          Nothing -> ["evolutionEntry @" ++ name before ++ " @" ++ name manifest.schemaType ++ " " ++
            oldDescription ++ " " ++ newDescription ++ " Evolution.evolution"]
          Just (state,closure) -> ["recipeEvolutionEntry @" ++ name before ++ " @" ++ state ++ " " ++
            oldDescription ++ " " ++ show closure ++ " Evolution.evolution"]
        Just _ -> []
      description = "evolutionDescriptionEntry @" ++ name before ++ " @" ++ name manifest.schemaType ++ " " ++
        oldDescription ++ " " ++ newDescription ++ " [" ++ intercalate ","
          ["(" ++ show reference ++ "," ++ state ++ ")" | (reference,(_,_,state)) <- zip references states] ++ "]"
      modules = nub (selectedModules ++ importedBindings ++ concat [names | (_,names,_) <- states])
  (_,exports) <- inspectExports libdir (roots ++ [generated]) selectedPackages modules
  let original path = maybe path Text.pack (lookup (Text.unpack path) origins)
      located = [entry { moduleSource = original entry.moduleSource } | entry <- exports]
  writeGuest generated located (nub (modules ++ map (Text.unpack . referenceModule) [before,manifest.schemaType])) (description : "describeEntry @() \"$import.unit\" (SchemaMetadata [] [] []) []" : entries ++ importedEntries)
  finishGuest compiler generated selectedPackages destination

-- All compiler inputs belong to target/helper sources. Stored recipe references
-- are candidate names only; absent names do not import historical implementations.
buildTargetEvolution :: FilePath -> FilePath -> FilePath -> [String] -> FilePath
  -> [RecipeReference] -> Maybe [Text.Text] -> IO ()
buildTargetEvolution compiler libdir generated basePackages destination references (Just requested)
  | not (null requested) = do
      roots <- ("src" :) <$> installedPluginRoots
      selected <- resolveModules libdir (".kyyn-change" : roots) (map Text.unpack requested)
      needs <- requiredBindings libdir (".kyyn-change" : roots) (basePackages ++ map ("-i" ++) roots) selected
      if needs.workspaceBindings then
        buildTargetEvolutionFull compiler libdir generated basePackages destination references (Just (map Text.pack selected))
      else buildModules compiler libdir generated basePackages destination selected
buildTargetEvolution compiler libdir generated basePackages destination references discovery =
  buildTargetEvolutionFull compiler libdir generated basePackages destination references discovery

buildTargetEvolutionFull :: FilePath -> FilePath -> FilePath -> [String] -> FilePath
  -> [RecipeReference] -> Maybe [Text.Text] -> IO ()
buildTargetEvolutionFull compiler libdir generated basePackages destination references discovery = do
  manifest <- Text.readFile "kb.dhall" >>= either fail pure . parseManifest
  pluginRoots <- installedPluginRoots
  runtime <- runtimeOptions compiler
  let roots = "src" : ".kyyn-change" : pluginRoots
      packages = basePackages ++ runtime ++ map ("-i" ++) roots
  (closure,metadata) <- inspectRoot compiler libdir generated "Target" packages roots manifest.schemaType manifest.schemaMetadata
  writeTargetEvolutionBindings generated roots manifest metadata
  queryBindings <- either fail pure (bindings manifest metadata)
  writeFile (generated </> "KyynQueryBindings.hs") queryBindings
  authored <- concat <$> traverse Sources.sourceFiles roots
  headers <- traverse (Sources.moduleHeader libdir) authored
  let modules = map fst headers
      imports = concatMap snd headers ++ maybe [] (map Text.unpack) discovery
      namedModules = nub [Text.unpack (referenceModule selected) | reference <- references,
        let name = case reference of OpenState value -> value; ClosedFlow value -> value,
        Right selected <- [qualifiedReference (case reference of OpenState _ -> True; _ -> False) name],
        Text.unpack (referenceModule selected) `elem` modules]
  needs <- requiredBindings libdir (roots ++ [generated]) packages
    (namedModules ++ either (const []) id (handleModules (handleImports imports)))
  when needs.toolBindings $ do
    (_,_,_,registrations) <- preparePlugins compiler libdir generated (basePackages ++ runtime)
    writeToolBindings generated roots registrations
  (_,namedExports) <- if null namedModules then pure ([],[]) else
    inspectExports libdir (roots ++ [generated]) packages namedModules
  resolved <- fmap concat $ forM namedModules $ \name -> do
    let symbols = [(symbol.exportName,symbol.exportKind) | entry <- namedExports,
          entry.moduleName == Text.pack name, symbol <- entry.moduleExports]
    pure [case reference of
      OpenState stateName -> "Kyyn.Workspace.Target.RecipeTypes." ++ Text.unpack stateName
      ClosedFlow _ -> "Kyyn.Workspace.Target.RecipeFlows." ++ name
      | reference <- references,
        let selected = case reference of OpenState value -> value; ClosedFlow value -> value,
        Right parsed <- [qualifiedReference (case reference of OpenState _ -> True; _ -> False) selected],
        Text.unpack (referenceModule parsed) == name,
        let symbol = Text.takeWhileEnd (/= '.') selected,
        (symbol,case reference of OpenState _ -> ExportType; ClosedFlow _ -> ExportValue) `elem` symbols]
  let handles = handleImportsWithStored imports resolved
  (_,importedModules,importedEntries,recipeBindings) <- writeRecipeHandles libdir generated packages roots roots manifest.schemaType handles
  let defaults = ["Kyyn.Workspace.Evolution","Kyyn.Workspace.Target","Kyyn.Workspace.Target.Fields","Kyyn.Workspace.FactEdits"]
      selected = case discovery of Nothing -> "Evolution" : defaults; Just [] -> defaults; Just names -> map Text.unpack names
      inspected = nub (selected ++ importedModules)
      rootName = Text.unpack (referenceName manifest.schemaType)
      unit = ["TargetEvolution.RecipeBinding (OpenState \"()\") (either (error . show) id (RuntimeBindings.recipeType @() \"()\"))"]
      execution = case discovery of
        Just _ -> []
        Nothing -> ["targetEvolutionEntry @" ++ rootName ++ " (" ++ show metadata ++ "," ++ show closure ++ ") [" ++
          intercalate "," (nub (recipeBindings ++ unit)) ++ "] Evolution.evolution",
          "TargetEvolution.targetProjectionEntry @" ++ rootName ++ " (" ++ show metadata ++ "," ++ show closure ++ ") [" ++
          intercalate "," (nub (recipeBindings ++ unit)) ++ "]"]
      description = "describeEntry @" ++ rootName ++ " \"$evolution.target\" (" ++ show metadata ++ ") " ++ show closure
  (_,exports) <- inspectExports libdir (roots ++ [generated]) packages inspected
  writeGuest generated exports (nub (inspected ++ [Text.unpack (referenceModule manifest.schemaType)]))
    (description : "describeEntry @() \"$import.unit\" (SchemaMetadata [] [] []) []" : execution ++ importedEntries)
  finishGuest compiler generated packages destination

writeGuest :: FilePath -> [ModuleDescription] -> [String] -> [String] -> IO ()
writeGuest generated exports modules entries =
  writeFile (generated </> "KyynGuestEntry.hs") (unlines
    (["{-# LANGUAGE TypeApplications, OverloadedStrings #-}","module KyynGuestEntry where",
      "import Kyyn.Runtime.Guest", "import Kyyn.Types.Guest", "import Kyyn.Types.GuestBuild (RecipeReference(..))", "import Kyyn.Types.SchemaMetadata", "import Kyyn.Contract (ProjectionError)",
      "import System.Environment (getArgs)", "import qualified Kyyn.Runtime.TargetEvolution as TargetEvolution", "import qualified Kyyn.Runtime.Bindings as RuntimeBindings"] ++ map ("import qualified " ++) modules ++
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
