{-# LANGUAGE GADTs, LambdaCase, DataKinds, OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation) where

import Control.Monad (forM, unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (eitherDecodeStrict, toJSON)
import GHC.Records (getField)
import Data.Coerce (coerce)
import Data.List (nub, stripPrefix, isPrefixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Evidence (validateReportContract)
import Kyyn.Domain.Contract (contractShape, contractId)
import Kyyn.Domain.CompiledEntry (CompiledConnector(..), compiledConnectors)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Guest (InspectedSchema(..), CheckedGuest, checkedEntries)
import qualified Kyyn.Types.Guest as G
import Kyyn.Domain.Diagnostic (Diagnostic(..), ValidationReport(..), errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, files, fileTree)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Domain.Plugin
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, decodeValue, encodeValue)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest)
import Kyyn.Plumbing.Capability.GuestInspection (GuestInspection, describeGuest)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeEntry)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (guestSources, GuestSelection(..))
import Kyyn.Plumbing.Protocol.ConnectorConfig (decodeInstances)
import Kyyn.Plumbing.Protocol.Plugin (decodeManifest)
import Kyyn.Plumbing.Protocol.Validation (decodeReport)
import Kyyn.Porcelain.Capability.PluginPreparation

runPluginPreparation :: (GuestCompilation :> es, GuestInspection :> es, GuestExecution :> es, DhallHandling :> es, Failure :> es)
  => Eff (PluginPreparation : es) a -> Eff es a
runPluginPreparation = interpret $ \_ -> \case
  PreparePackages code -> runExceptT (prepare code)
  PreparePlugins code -> runExceptT (prepare code >>= configure code)
  PreparePluginsFromGuest code program description -> runExceptT (prepareFromGuest code program description >>= configure code)
  ValidatePlugins plugins -> runExceptT $ do
    reports <- forM [(plugin,instanceName,entry,config) |
      PreparedPlugin (PreparedPackage plugin _ _) instances <- plugins,
      ConfiguredConnector instanceName _ connector config <- instances, let entry = getField @"validationEntry" connector] $
      \(plugin,instanceName,entry,CheckedValue _ config) -> do
        let label = pluginNameText plugin ++ "/" ++ coerce instanceName
        bytes <- ExceptT (Right <$> executeEntry entry config)
        ValidationReport report <- checked label (decodeReport bytes)
        pure (map (locate label) report)
    pure (ValidationReport (concat reports))

prepare :: (GuestCompilation :> es, GuestInspection :> es, GuestExecution :> es, DhallHandling :> es, Failure :> es)
  => FileTree -> ExceptT [Diagnostic] (Eff es) [PreparedPackage]
prepare code = do
  let entries = [(relativeName path,bytes) | (path,bytes) <- files code]
      names = nub [takeWhile (/= '/') rest | (path,_) <- entries, Just rest <- [stripPrefix "plugins/packages/" path]]
  if null names then pure [] else do
    captured <- checked "plugins" (guestSources PluginEntries (files code))
    program <- located "plugins" (compileGuest captured)
    description <- located "plugins" (describeGuest program)
    unless (all (\entry -> case entry of G.ConnectorEntry{} -> True; _ -> False) (checkedEntries description))
      (bad "plugins" "Plugin selection contains non-connector entries")
    prepareFromGuest code program description

prepareFromGuest :: (GuestExecution :> es, DhallHandling :> es, Failure :> es)
  => FileTree -> CompiledProgram -> CheckedGuest -> ExceptT [Diagnostic] (Eff es) [PreparedPackage]
prepareFromGuest code program description = do
  let entries = [(relativeName path,bytes) | (path,bytes) <- files code]
      names = nub [takeWhile (/= '/') rest | (path,_) <- entries, Just rest <- [stripPrefix "plugins/packages/" path]]
      connectors = compiledConnectors program description
      owner (CompiledSource identity _ _ _ _ _) = identity
      owner (CompiledSink identity _ _ _ _) = identity
  unless (all ((`elem` names) . Text.unpack . G.connectorPlugin . owner) connectors)
    (bad "plugins" "Guest describes an uninstalled plugin package")
  forM names $ \name -> do
    let label = "plugin " ++ name
        prefix = "plugins/packages/" ++ name ++ "/source/"
        packageFiles = [(rest,bytes) | (path,bytes) <- entries, Just rest <- [stripPrefix prefix path]]
    manifestBytes <- maybe (bad label "Missing kyyn-plugin.dhall") pure (lookup "kyyn-plugin.dhall" packageFiles)
    manifest <- located label (decodeManifest manifestBytes)
    unless (pluginNameText (manifestName manifest) == name) (bad label "Manifest name differs from installed package directory")
    package <- checked label . fileTree =<< traverse (\(path,bytes) -> (,) <$> checked label (relativePath path) <*> pure bytes) packageFiles
    prepared <- forM [connector | connector <- connectors, (owner connector).connectorPlugin == Text.pack name] $ \connector -> do
      let identity = owner connector
          connectorLabel = label ++ "/" ++ Text.unpack identity.connectorType
      kind <- checked connectorLabel (connectorTypeName (Text.unpack identity.connectorType))
      case connector of
        CompiledSource _ contracts acquisition validator login captured -> do
          let (config,options,payload,position,report) = case contracts of
                G.StatelessContracts c o p -> (c,o,p,Nothing,Nothing)
                G.StatefulContracts c o p s r -> (c,o,p,Just s,Just r)
          mapM_ (checked connectorLabel . validateReportContract . getField @"contract") report
          methods <- forM captured $ \(method,entry) -> do
            selectedName <- checked connectorLabel (methodName (Text.unpack method.capturedName))
            let G.CapturedContracts input _ result = method.capturedInvocation.invocationContract
            pure (PreparedMethod selectedName (Text.unpack method.capturedDescription) input.contract result.contract entry)
          pure (PreparedConnector kind config.contract payload.contract acquisition validator methods
            (getField @"contract" <$> options) login (getField @"contract" <$> position) (getField @"contract" <$> report))
        CompiledSink _ (G.SinkContracts config options input result) publication validator defaults -> do
          bytes <- ExceptT (Right <$> executeEntry defaults (toJSON G.SinkDefaultsInvocation))
          value <- checked connectorLabel (eitherDecodeStrict bytes)
          _ <- located connectorLabel (encodeValue (contractShape options.contract) value)
          pure (PreparedSinkConnector kind config.contract validator input.contract options.contract result.contract publication
            (CheckedValue (contractId options.contract) value))
    pure (PreparedPackage (manifestName manifest) (packageIdentity package) prepared)

configure :: DhallHandling :> es => FileTree -> [PreparedPackage] -> ExceptT [Diagnostic] (Eff es) [PreparedPlugin]
configure code packages = do
  let entries = [(relativeName path,bytes) | (path,bytes) <- files code]
  plugins <- forM packages $ \package@(PreparedPackage plugin _ connectors) -> do
    let name = pluginNameText plugin
        label = "plugin " ++ name
        configFile = "plugins/config/" ++ name ++ ".dhall"
        configContracts = [(getField @"connectorType" c,getField @"configContract" c) | c <- connectors]
    instances <- case lookup configFile entries of
      Nothing -> pure []
      Just bytes -> do
        text <- checked label (either (Left . show) Right (Text.decodeUtf8' bytes))
        value <- located label (decodeValue (instanceShape [(n,contractShape c) | (n,c) <- configContracts]) text)
        selected <- checked label (decodeInstances value)
        forM selected $ \(instanceName,binding,kind,configuration) -> case
          [c | c <- connectors, getField @"connectorType" c == kind] of
            [c] -> pure
              (ConfiguredConnector instanceName binding c (CheckedValue (contractId (getField @"configContract" c)) configuration))
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
locate label (Diagnostic severity code message location) = Diagnostic severity code (Text.pack label <> ": " <> message) location
checked :: String -> Either String a -> ExceptT [Diagnostic] (Eff es) a
checked label = either (bad label) pure
bad :: String -> String -> ExceptT [Diagnostic] (Eff es) a
bad label message = throwE [errorDiagnostic "plugin.preparation" (label ++ ": " ++ message)]
