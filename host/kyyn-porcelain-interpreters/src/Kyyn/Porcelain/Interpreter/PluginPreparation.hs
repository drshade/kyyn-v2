{-# LANGUAGE GADTs, LambdaCase, DataKinds #-}
module Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation) where

import Control.Monad (forM, unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (encode, eitherDecodeStrict)
import GHC.Records (getField)
import Data.Coerce (coerce)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.List (nub, stripPrefix, isPrefixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (rootType, contractShape, contractId, checkContract)
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Domain.Diagnostic (Diagnostic(..), ValidationReport(..), errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, files, fileTree)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Domain.Plugin
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, decodeValue, encodeValue)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeCompiledEntry, executeCompiled)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit(..))
import Kyyn.Plumbing.Capability.GuestCompilation.Types (guestSources, packageIdentity)
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection, inspectPluginFunction)
import Kyyn.Plumbing.Protocol.ConnectorConfig (decodeInstances)
import Kyyn.Plumbing.Protocol.Plugin (decodeManifest)
import Kyyn.Plumbing.Protocol.PluginRegistration (registrationSources, decodeConnectors, registrationFailure)
import Kyyn.Plumbing.Protocol.PluginInvocation (acquisitionSources, statefulAcquisitionSources, capturedReadSources, loginSources, sinkSources)
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
      ConfiguredConnector instanceName _ connector config <- instances, let entry = getField @"validationEntry" connector] $
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
    (encoded,registrationExit) <- ExceptT (Right <$> executeCompiled registrationEntry Bytes.empty)
    case registrationExit of
      ProcessExit 0 _ -> pure ()
      ProcessExit _ stderr -> bad label (registrationFailure stderr)
    declarations <- checked label (decodeConnectors encoded)
    let sources = authored ++ files sdk
    sourceTree <- checked label (fileTree sources)
    let contract structure = either throwE pure (checkContract structure (SchemaMetadata [] [] []))
    connectors <- forM declarations $ \case
     SinkDeclaration connector validate publish defaults -> do
      let connectorLabel = label ++ "/" ++ coerce connector
      signature <- located connectorLabel (inspectPluginFunction sourceTree SinkEntry publish)
      (c,o,i,r) <- case signature of
        SinkSignature c o i r -> pure (c,o,i,r)
        _ -> bad connectorLabel "Expected sink signature"
      config <- contract c
      options <- contract o
      input <- contract i
      result <- contract r
      adapter <- checked connectorLabel (sinkSources c o i r publish defaults sources)
      publisher <- located connectorLabel (compileGuest adapter)
      validation <- checked connectorLabel (validationSources c validate sources)
      validator <- located connectorLabel (compileGuest validation)
      bytes <- ExceptT (Right <$> executeCompiledEntry connectorLabel publisher "\"Defaults\"")
      value <- checked connectorLabel (eitherDecodeStrict bytes)
      _ <- located connectorLabel (encodeValue (contractShape options) value)
      pure (PreparedSinkConnector connector config validator input options result publisher (CheckedValue (contractId options) value))
     ConnectorDeclaration connector fetch validate declaredMethods login -> do
      let connectorLabel = label ++ "/" ++ coerce connector
      signature <- located connectorLabel (inspectPluginFunction sourceTree AcquisitionEntry fetch)
      (configType,optionsType,payloadType,positionType) <- case signature of
        FetchSignature c o p -> pure (c,o,p,Nothing)
        StatefulFetchSignature c o p s -> pure (c,o,p,Just s)
        _ -> bad connectorLabel "Expected acquisition signature"
      config <- contract configType
      payload <- contract payloadType
      options <- traverse contract optionsType
      position <- traverse contract positionType
      acquisition <- checked connectorLabel (case position of
        Nothing -> acquisitionSources (rootType config) (rootType payload) (rootType <$> options) fetch sources
        Just p -> statefulAcquisitionSources (rootType config) (rootType payload) (rootType <$> options) (rootType p) fetch sources)
      fetchEntry <- located connectorLabel (compileGuest acquisition)
      validation <- checked connectorLabel (validationSources (rootType config) validate sources)
      validationEntry <- located (connectorLabel ++ " " ++ validate ++ " (expected Config -> ValidationReport)") (compileGuest validation)
      methods <- forM declaredMethods $ \(CapturedMethodDeclaration selectedName description implementation) -> do
        let methodLabel = connectorLabel ++ "/" ++ coerce selectedName
        methodSignature <- located methodLabel (inspectPluginFunction sourceTree CapturedReadEntry implementation)
        (inputType,resultType) <- case methodSignature of
          ReadSignature i p r | p == payloadType -> pure (i,r)
          ReadSignature{} -> bad methodLabel (implementation ++ ": captured reader Payload differs from fetch Payload")
          _ -> bad methodLabel "Expected captured-read signature"
        input <- contract inputType
        output <- contract resultType
        adapter <- checked connectorLabel (capturedReadSources (rootType input) (rootType payload) (rootType output) implementation sources)
        methodEntry <- located (connectorLabel ++ "/" ++ coerce selectedName) (compileGuest adapter)
        pure (PreparedMethod selectedName description input output methodEntry)
      loginEntry <- traverse (\selected -> do
        adapter <- checked connectorLabel (loginSources (rootType config) selected sources)
        located (connectorLabel ++ " " ++ selected ++ " (expected Config -> PluginLogin (Either LoginError ()))") (compileGuest adapter)) login
      pure (PreparedConnector connector config payload fetchEntry validationEntry methods options loginEntry position)
    pure (PreparedPackage (manifestName manifest) (packageIdentity captured) connectors)

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
