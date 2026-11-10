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
  unique "entry" (concatMap G.entryNames description.entries)
  entries <- traverse checkEntry description.entries
  unique "recipe" [name | G.RecipeEntry _ name _ <- entries]
  unique "tool" [name | G.ToolEntry _ name _ _ <- entries]
  let connectors = [identity | G.ConnectorEntry identity _ <- entries]
  ensure (length connectors == length (nub connectors)) "guest.connectors" "Duplicate connector identity"
  unique "module" (map G.moduleName description.modules)
  forM_ description.modules $ \selected -> do
    unless (Text.null selected.moduleSource) (void (source selected.moduleSource))
    -- DuplicateRecordFields may export several selectors with the same name
    -- and namespace. GHC distinguishes them by their parent record type, which
    -- is present in each compiler-rendered selector signature.
    let symbols = [(e.exportName,e.exportKind,e.exportSignature) | e <- selected.moduleExports]
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
  G.EvolutionEntry name contracts -> G.EvolutionEntry name <$> case contracts of
    G.TargetEvolutionContracts target -> G.TargetEvolutionContracts <$> root target
  G.RecipeEntry name reference (G.RecipeContracts rootContract arguments state) -> do
    either (Left . pure . errorDiagnostic "guest.recipe") (const (Right ())) (Plugin.bindingModule (Text.unpack reference))
    G.RecipeEntry name reference <$> (G.RecipeContracts <$> root rootContract <*> check arguments <*> check state)
  G.ToolEntry entryName name description contracts -> do
    either (Left . pure . errorDiagnostic "guest.tool") (const (Right ())) (Plugin.methodName (Text.unpack name))
    G.ToolEntry entryName name description <$> traverse check contracts
  G.QueryEntry name (G.QueryContracts rootContract arguments result) ->
    G.QueryEntry name <$> (G.QueryContracts <$> root rootContract <*> check arguments <*> check result)
  G.ConnectorEntry identity selected -> do
    checkConnector identity
    checked <- traverse check selected
    checkConnectorContracts checked
    pure (G.ConnectorEntry identity checked)
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

-- Required roles are structural. Repeated type contracts must still agree:
-- each adapter was compiled from an independently authored function.
checkConnectorContracts :: G.ConnectorEntries InspectedSchema -> Either [Diagnostic] ()
checkConnectorContracts selected = case selected of
  G.SourceEntries config acquisition login methods -> do
    let (configuration,payload) = case acquisition.invocationContract of
          G.StatelessContracts c _ p -> (c,p)
          G.StatefulContracts c _ p _ _ -> (c,p)
    compatible "configuration" configuration config.invocationContract
    forM_ login $ \entry -> compatible "configuration" configuration entry.invocationContract
    unique "method" (map G.capturedName methods)
    forM_ methods $ \method -> do
      either (Left . pure . errorDiagnostic "guest.method") (const (Right ()))
        (Plugin.methodName (Text.unpack method.capturedName))
      let G.CapturedContracts _ actual _ = method.capturedInvocation.invocationContract
      compatible "payload" payload actual
  G.SinkEntries config publication defaults -> do
    let G.SinkContracts configuration options _ _ = publication.invocationContract
    compatible "configuration" configuration config.invocationContract
    compatible "sink options" options defaults.invocationContract
  where
    compatible label a b = ensure (contractId a.contract == contractId b.contract)
      "guest.connector-contract" ("Inconsistent connector " ++ label ++ " contracts")

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
