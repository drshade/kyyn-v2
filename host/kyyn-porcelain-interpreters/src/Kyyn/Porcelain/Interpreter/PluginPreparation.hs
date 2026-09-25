{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation) where

import Control.Monad (forM, unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (encode)
import Data.Coerce (coerce)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.List (nub, stripPrefix, isPrefixOf)
import qualified Data.Text.Encoding as Text
import Numeric (showHex)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (rootType, contractShape, contractId)
import Kyyn.Domain.Diagnostic (Diagnostic(..), ValidationReport(..), errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, files, fileTree)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Domain.Plugin
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, decodeValue)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeCompiledEntry)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (guestSources, sourceIdentity)
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection, InspectedSchema(..), inspectType)
import Kyyn.Plumbing.Protocol.ConnectorConfig (decodeInstances)
import Kyyn.Plumbing.Protocol.Plugin (decodeManifest)
import Kyyn.Plumbing.Protocol.PluginRegistration (registrationSources, decodeConnectors)
import Kyyn.Plumbing.Protocol.PluginInvocation (acquisitionSources, capturedReadSources)
import Kyyn.Plumbing.Protocol.Validation (validationSources, decodeReport)
import Kyyn.Porcelain.Capability.PluginPreparation

runPluginPreparation :: (GuestCompilation :> es, GuestExecution :> es, SchemaInspection :> es, DhallHandling :> es, Failure :> es)
  => FileTree -> Eff (PluginPreparation : es) a -> Eff es a
runPluginPreparation sdk = interpret $ \_ -> \case
  PreparePackages code -> runExceptT (prepare sdk code)
  PreparePlugins code -> runExceptT (prepare sdk code >>= configure code)
  ValidatePlugins plugins -> runExceptT $ do
    reports <- forM [(plugin,instanceName,entry,config) |
      PreparedPlugin (PreparedPackage plugin _ _) instances <- plugins,
      ConfiguredConnector instanceName _ (PreparedConnector _ _ _ _ entry _ _) config <- instances] $
      \(plugin,instanceName,entry,CheckedValue _ config) -> do
        let label = pluginNameText plugin ++ "/" ++ coerce instanceName
        bytes <- ExceptT (Right <$> executeCompiledEntry label entry (Lazy.toStrict (encode config)))
        ValidationReport report <- checked label (decodeReport bytes)
        pure (map (locate label) report)
    pure (ValidationReport (concat reports))

prepare :: (GuestCompilation :> es, GuestExecution :> es, SchemaInspection :> es, DhallHandling :> es, Failure :> es)
  => FileTree -> FileTree -> ExceptT [Diagnostic] (Eff es) [PreparedPackage]
prepare sdk code = do
  let entries = [(relativeName path,bytes) | (path,bytes) <- files code]
      names = nub [takeWhile (/= '/') rest | (path,_) <- entries, Just rest <- [stripPrefix "plugins/packages/" path]]
  forM names $ \name -> do
    let label = "plugin " ++ name
        prefix = "plugins/packages/" ++ name ++ "/source/"
        packageFiles = [(rest,bytes) | (path,bytes) <- entries, Just rest <- [stripPrefix prefix path]]
    manifestBytes <- maybe (bad label "Missing kyyn-plugin.dhall") pure (lookup "kyyn-plugin.dhall" packageFiles)
    manifest <- located label (decodeManifest manifestBytes)
    unless (pluginNameText (manifestName manifest) == name) (bad label "Manifest name differs from installed package directory")
    package <- traverse (\(path,bytes) -> (,) <$> checked label (relativePath path) <*> pure bytes) packageFiles
    entry <- checked label (relativePath ("src/" ++ map (\c -> if c == '.' then '/' else c) (entryModule manifest) ++ ".hs"))
    captured <- checked label (guestSources entry package)
    authored <- traverse (\(path,bytes) -> (,) <$> checked label (relativePath path) <*> pure bytes)
      [(rest,bytes) | (path,bytes) <- packageFiles, Just rest <- [stripPrefix "src/" path]]
    registration <- checked label (registrationSources (entryModule manifest) (authored ++ files sdk))
    registrationEntry <- located label (compileGuest registration)
    encoded <- ExceptT (Right <$> executeCompiledEntry label registrationEntry Bytes.empty)
    declarations <- checked label (decodeConnectors encoded)
    let sources = authored ++ files sdk
    sourceTree <- checked label (fileTree sources)
    let inspect selected = do
          InspectedSchema contract _ <- located label (inspectType sourceTree selected)
          pure contract
    connectors <- forM declarations $ \(ConnectorDeclaration connector configType payloadType fetch validate declaredMethods optionsType) -> do
      let connectorLabel = label ++ "/" ++ coerce connector
      config <- inspect configType
      payload <- inspect payloadType
      options <- traverse inspect optionsType
      acquisition <- checked connectorLabel (acquisitionSources (rootType config) (rootType payload) (rootType <$> options) fetch sources)
      fetchEntry <- located connectorLabel (compileGuest acquisition)
      validation <- checked connectorLabel (validationSources (rootType config) validate sources)
      validationEntry <- located connectorLabel (compileGuest validation)
      methods <- forM declaredMethods $ \(CapturedMethodDeclaration selectedName description inputType resultType implementation) -> do
        input <- inspect inputType
        output <- inspect resultType
        adapter <- checked connectorLabel (capturedReadSources (rootType input) (rootType payload) (rootType output) implementation sources)
        methodEntry <- located (connectorLabel ++ "/" ++ coerce selectedName) (compileGuest adapter)
        pure (PreparedMethod selectedName description input output methodEntry)
      pure (PreparedConnector connector config payload fetchEntry validationEntry methods options)
    pure (PreparedPackage (manifestName manifest) (PackageIdentity (hex (sourceIdentity captured))) connectors)

configure :: DhallHandling :> es => FileTree -> [PreparedPackage] -> ExceptT [Diagnostic] (Eff es) [PreparedPlugin]
configure code packages = do
  let entries = [(relativeName path,bytes) | (path,bytes) <- files code]
  plugins <- forM packages $ \package@(PreparedPackage plugin _ connectors) -> do
    let name = pluginNameText plugin
        label = "plugin " ++ name
        configFile = "plugins/config/" ++ name ++ ".dhall"
        configContracts = [(connector,contract) | PreparedConnector connector contract _ _ _ _ _ <- connectors]
    instances <- case lookup configFile entries of
      Nothing -> pure []
      Just bytes -> do
        text <- checked label (either (Left . show) Right (Text.decodeUtf8' bytes))
        value <- located label (decodeValue (instanceShape [(n,contractShape c) | (n,c) <- configContracts]) text)
        selected <- checked label (decodeInstances value)
        forM selected $ \(instanceName,binding,kind,configuration) -> case
          [c | c@(PreparedConnector n _ _ _ _ _ _) <- connectors, n == kind] of
            [c@(PreparedConnector _ contract _ _ _ _ _)] -> pure
              (ConfiguredConnector instanceName binding c (CheckedValue (contractId contract) configuration))
            _ -> bad (label ++ "/" ++ coerce instanceName) "Unknown connector type"
    pure (PreparedPlugin package instances)
  let bindings = [binding | PreparedPlugin _ instances <- plugins, ConfiguredConnector _ binding _ _ <- instances]
      expected = ["plugins/config/" ++ pluginNameText plugin ++ ".dhall" | PreparedPackage plugin _ _ <- packages]
  unless (length bindings == length (nub bindings)) (bad "plugins" "Connector bindings must be unique across the KB")
  unless (all (\(path,_) -> not ("plugins/config/" `isPrefixOf` path) || path `elem` expected) entries)
    (bad "plugins" "Configuration exists without a corresponding installed plugin")
  pure plugins

located :: String -> Eff es (Either [Diagnostic] a) -> ExceptT [Diagnostic] (Eff es) a
located label action = ExceptT (fmap (either (Left . map (locate label)) Right) action)
locate :: String -> Diagnostic -> Diagnostic
locate label (Diagnostic severity code message location) = Diagnostic severity code (label ++ ": " ++ message) location
checked :: String -> Either String a -> ExceptT [Diagnostic] (Eff es) a
checked label = either (bad label) pure
bad :: String -> String -> ExceptT [Diagnostic] (Eff es) a
bad label message = throwE [errorDiagnostic "plugin.preparation" (label ++ ": " ++ message)]
hex :: Bytes.ByteString -> String
hex = concatMap (\byte -> let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits) . Bytes.unpack
