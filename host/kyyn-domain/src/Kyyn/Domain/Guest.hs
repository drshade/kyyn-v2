{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Domain.Guest
  ( CheckedGuest, CheckedEntry, InspectedSchema(..), checkGuest, checkedEntries, checkedModules
  ) where

import Control.Monad (unless, forM_, void)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Domain.Contract
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import qualified Kyyn.Domain.Plugin as Plugin
import Kyyn.Domain.Path (RelativePath, relativePath)
import qualified Kyyn.Types.Guest as G

-- Descriptions cross a process boundary. The host checks structure, annotations
-- and identity itself before exposing typed contracts to its workflows.
data CheckedGuest = CheckedGuest [CheckedEntry] [G.ModuleDescription] deriving (Eq, Show)
data InspectedSchema = InspectedSchema
  { contract :: CheckedContract, loadedSources :: [RelativePath] } deriving (Eq, Show)
type CheckedEntry = G.GuestEntry InspectedSchema

checkedEntries :: CheckedGuest -> [CheckedEntry]
checkedEntries (CheckedGuest entries _) = entries

checkedModules :: CheckedGuest -> [G.ModuleDescription]
checkedModules (CheckedGuest _ exports) = exports

checkGuest :: G.GuestDescription -> Either [Diagnostic] CheckedGuest
checkGuest description = do
  ensure (description.protocol == G.protocolIdentity) "guest.protocol" "Unrecognized guest protocol"
  unique "entry" (map G.entryName description.entries)
  entries <- traverse checkEntry description.entries
  let methods = [(m.pluginName,m.connectorName,m.methodName) | G.CapturedReadEntry _ m _ <- entries]
  ensure (length methods == length (nub methods)) "guest.methods" "Duplicate captured method identity"
  checkConnectorContracts entries
  unique "module" (map G.moduleName description.modules)
  forM_ description.modules $ \selected -> do
    unless (Text.null selected.moduleSource) (void (source selected.moduleSource))
    let symbols = [(e.exportName,e.exportKind) | e <- selected.moduleExports]
    ensure (length symbols == length (nub symbols)) "guest.exports" "Duplicate exported symbol"
    forM_ selected.moduleExports $ \exported ->
      ensure (all (not . Text.null) [exported.exportName,exported.exportSignature,exported.exportOrigin])
        "guest.exports" "Incomplete exported symbol"
  pure (CheckedGuest entries description.modules)

checkEntry :: G.EntryDescription -> Either [Diagnostic] CheckedEntry
checkEntry entry = case entry of
  G.ValidatorEntry name selected -> do
    ensure (name == "validate") "guest.entry" "Validator must use the validate entry"
    G.ValidatorEntry name <$> root selected
  G.QueryEntry name (G.QueryContracts rootContract arguments result) ->
    G.QueryEntry name <$> (G.QueryContracts <$> root rootContract <*> check arguments <*> check result)
  G.ConfigurationEntry name connector config -> do
    checkConnector connector
    G.ConfigurationEntry name connector <$> check config
  G.LoginEntry name connector config -> do
    checkConnector connector
    G.LoginEntry name connector <$> check config
  G.SinkEntry name connector contracts -> do
    checkConnector connector
    G.SinkEntry name connector <$> traverse check contracts
  G.SinkDefaultsEntry name connector options -> do
    checkConnector connector
    G.SinkDefaultsEntry name connector <$> check options
  G.AcquisitionEntry name connector contracts -> do
    checkConnector connector
    G.AcquisitionEntry name connector <$> traverse check contracts
  G.CapturedReadEntry name method contracts -> do
    let nominal = either (Left . pure . errorDiagnostic "guest.method") (const (Right ()))
    nominal (Plugin.pluginName (Text.unpack method.pluginName))
    nominal (Plugin.connectorTypeName (Text.unpack method.connectorName))
    nominal (Plugin.methodName (Text.unpack method.methodName))
    G.CapturedReadEntry name method <$> traverse check contracts
  G.ContractEntry name selected -> G.ContractEntry name <$> check selected
  where
    root selected = do
      inspected <- check selected
      void (checkRootLayout inspected.contract)
      pure inspected
    check selected = do
      sources <- traverse source selected.loadedSources
      contract <- checkContract selected.structure selected.metadata
      ensure (contractFingerprint (contractId contract) == Text.unpack selected.identity)
        "guest.identity" "Guest contract fingerprint disagrees with its structure and metadata"
      pure (InspectedSchema contract sources)

-- A connector's separate entry points must agree on its shared contracts.
-- Completeness for a particular workflow is checked when preparing that workflow.
checkConnectorContracts :: [CheckedEntry] -> Either [Diagnostic] ()
checkConnectorContracts entries = do
  let roles = concatMap role entries
  ensure (length roles == length (nub roles)) "guest.connectors" "Duplicate connector entry role"
  compatible "configuration" (concatMap configs entries)
  compatible "payload" (concatMap payloads entries)
  compatible "sink options" (concatMap options entries)
  let sources = [connector | G.AcquisitionEntry _ connector _ <- entries]
      sinks = [connector | G.SinkEntry _ connector _ <- entries]
  ensure (null [connector | connector <- sources, connector `elem` sinks])
    "guest.connectors" "A connector cannot be both a source and a sink"
  where
    role entry = case entry of
      G.ConfigurationEntry _ connector _ -> [("configuration" :: String,connector)]
      G.LoginEntry _ connector _ -> [("login",connector)]
      G.AcquisitionEntry _ connector _ -> [("acquisition",connector)]
      G.SinkEntry _ connector _ -> [("sink",connector)]
      G.SinkDefaultsEntry _ connector _ -> [("defaults",connector)]
      _ -> []
    configs entry = case entry of
      G.ConfigurationEntry _ connector config -> [(connector,config)]
      G.LoginEntry _ connector config -> [(connector,config)]
      G.AcquisitionEntry _ connector (G.StatelessContracts config _ _) -> [(connector,config)]
      G.AcquisitionEntry _ connector (G.StatefulContracts config _ _ _ _) -> [(connector,config)]
      G.SinkEntry _ connector (G.SinkContracts config _ _ _) -> [(connector,config)]
      _ -> []
    payloads entry = case entry of
      G.AcquisitionEntry _ connector (G.StatelessContracts _ _ payload) -> [(connector,payload)]
      G.AcquisitionEntry _ connector (G.StatefulContracts _ _ payload _ _) -> [(connector,payload)]
      G.CapturedReadEntry _ method (G.CapturedContracts _ payload _) ->
        [(G.ConnectorIdentity method.pluginName method.connectorName,payload)]
      _ -> []
    options entry = case entry of
      G.SinkEntry _ connector (G.SinkContracts _ selected _ _) -> [(connector,selected)]
      G.SinkDefaultsEntry _ connector selected -> [(connector,selected)]
      _ -> []
    compatible label values = forM_ values $ \(connector,selected) ->
      forM_ [other | (identity,other) <- values, identity == connector] $ \other ->
        ensure (contractId selected.contract == contractId other.contract) "guest.connector-contract"
          ("Inconsistent " ++ label ++ " contracts for " ++ Text.unpack connector.connectorPlugin ++ "/" ++ Text.unpack connector.connectorType)

checkConnector :: G.ConnectorIdentity -> Either [Diagnostic] ()
checkConnector connector = do
  let nominal = either (Left . pure . errorDiagnostic "guest.connector") (const (Right ()))
  nominal (Plugin.pluginName (Text.unpack connector.connectorPlugin))
  nominal (Plugin.connectorTypeName (Text.unpack connector.connectorType))

source :: Text -> Either [Diagnostic] RelativePath
source path = case relativePath (Text.unpack path) of
  Left problem -> Left [errorDiagnostic "guest.source" problem]
  Right selectedPath -> pure selectedPath

unique :: String -> [Text] -> Either [Diagnostic] ()
unique label names = ensure (all (not . Text.null) names && length names == length (nub names))
  "guest.names" ("Guest " ++ label ++ " names must be nonempty and unique")

ensure :: Bool -> String -> String -> Either [Diagnostic] ()
ensure condition code message = unless condition (Left [errorDiagnostic code message])
