{-# LANGUAGE GADTs, LambdaCase, DataKinds, OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation) where

import Control.Monad (forM, unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (eitherDecodeStrict, object)
import GHC.Records (getField)
import Data.Coerce (coerce)
import Data.List (nub, stripPrefix, isPrefixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Evidence (validateReportContract)
import Kyyn.Domain.Contract (contractShape, contractId)
import Kyyn.Domain.CompiledEntry (CompiledEntry, compiledEntries, entryDescription)
import Kyyn.Domain.Guest (InspectedSchema(..), checkedEntries)
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
    let handles = compiledEntries program description
    unless (all (maybe False ((`elem` names) . Text.unpack . G.connectorPlugin) . owner) (checkedEntries description))
      (bad "plugins" "Guest plugin selection describes unexpected entries or packages")
    let identities = [identity | entry <- checkedEntries description, identity <- case entry of
          G.AcquisitionEntry _ selected _ -> [selected]
          G.SinkEntry _ selected _ -> [selected]
          _ -> []]
    unless (all (maybe False (`elem` identities) . owner) (checkedEntries description))
      (bad "plugins" "Connector entry has no corresponding acquisition or sink")
    forM names $ \name -> do
      let label = "plugin " ++ name
          prefix = "plugins/packages/" ++ name ++ "/source/"
          packageFiles = [(rest,bytes) | (path,bytes) <- entries, Just rest <- [stripPrefix prefix path]]
      manifestBytes <- maybe (bad label "Missing kyyn-plugin.dhall") pure (lookup "kyyn-plugin.dhall" packageFiles)
      manifest <- located label (decodeManifest manifestBytes)
      unless (pluginNameText (manifestName manifest) == name) (bad label "Manifest name differs from installed package directory")
      package <- checked label . fileTree =<< traverse (\(path,bytes) -> (,) <$> checked label (relativePath path) <*> pure bytes) packageFiles
      connectors <- forM [handle | handle <- handles, case entryDescription handle of
        G.AcquisitionEntry _ identity _ -> identity.connectorPlugin == Text.pack name
        G.SinkEntry _ identity _ -> identity.connectorPlugin == Text.pack name
        _ -> False] $ \handle -> case entryDescription handle of
          G.AcquisitionEntry _ identity contracts -> do
            let connectorLabel = label ++ "/" ++ Text.unpack identity.connectorType
                (config,options,payload,position,report) = case contracts of
                  G.StatelessContracts c o p -> (c,o,p,Nothing,Nothing)
                  G.StatefulContracts c o p s r -> (c,o,p,Just s,Just r)
            validator <- one connectorLabel [entry | entry <- handles,
              G.ConfigurationEntry _ actual _ <- [entryDescription entry], actual == identity]
            kind <- checked connectorLabel (connectorTypeName (Text.unpack identity.connectorType))
            mapM_ (checked connectorLabel . validateReportContract . getField @"contract") report
            methods <- forM [(entry,method,input,result) | entry <- handles,
              G.CapturedReadEntry _ method (G.CapturedContracts input _ result) <- [entryDescription entry],
              method.pluginName == identity.connectorPlugin, method.connectorName == identity.connectorType] $ \(entry,method,input,result) -> do
                selectedName <- checked connectorLabel (methodName (Text.unpack method.methodName))
                pure (PreparedMethod selectedName (Text.unpack method.methodDescription) input.contract result.contract entry)
            let logins = [entry | entry <- handles, G.LoginEntry _ actual _ <- [entryDescription entry], actual == identity]
            login <- case logins of [] -> pure Nothing; _ -> Just <$> one connectorLabel logins
            pure (PreparedConnector kind config.contract payload.contract handle validator methods
              (getField @"contract" <$> options) login (getField @"contract" <$> position) (getField @"contract" <$> report))
          G.SinkEntry _ identity (G.SinkContracts config options input result) -> do
            let connectorLabel = label ++ "/" ++ Text.unpack identity.connectorType
            validator <- one connectorLabel [entry | entry <- handles,
              G.ConfigurationEntry _ actual _ <- [entryDescription entry], actual == identity]
            defaults <- one connectorLabel [entry | entry <- handles,
              G.SinkDefaultsEntry _ actual _ <- [entryDescription entry], actual == identity]
            kind <- checked connectorLabel (connectorTypeName (Text.unpack identity.connectorType))
            bytes <- ExceptT (Right <$> executeEntry defaults (object []))
            value <- checked connectorLabel (eitherDecodeStrict bytes)
            _ <- located connectorLabel (encodeValue (contractShape options.contract) value)
            pure (PreparedSinkConnector kind config.contract validator input.contract options.contract result.contract handle
              (CheckedValue (contractId options.contract) value))
          _ -> bad label "Expected source or sink entry"
      pure (PreparedPackage (manifestName manifest) (packageIdentity package) connectors)

owner :: G.GuestEntry a -> Maybe G.ConnectorIdentity
owner entry = case entry of
  G.ConfigurationEntry _ identity _ -> Just identity
  G.LoginEntry _ identity _ -> Just identity
  G.AcquisitionEntry _ identity _ -> Just identity
  G.SinkEntry _ identity _ -> Just identity
  G.SinkDefaultsEntry _ identity _ -> Just identity
  G.CapturedReadEntry _ method _ -> Just (G.ConnectorIdentity method.pluginName method.connectorName)
  _ -> Nothing

one :: String -> [CompiledEntry] -> ExceptT [Diagnostic] (Eff es) CompiledEntry
one _ [entry] = pure entry
one label _ = bad label "Missing or ambiguous required connector entry"

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
