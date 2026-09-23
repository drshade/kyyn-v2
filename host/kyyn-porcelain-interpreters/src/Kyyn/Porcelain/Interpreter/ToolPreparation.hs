{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation) where

import Control.Monad (forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (stripPrefix)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (rootType)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Domain.Root (RootDefinition(..))
import Kyyn.Domain.Tool (ToolDefinition(..), ToolDescriptor(..))
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest)
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection, InspectedSchema(..), inspectType)
import Kyyn.Plumbing.Protocol.Tool (ConnectorInterface(..), InstanceBinding(..), toolBindings, toolSources)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.RootStore (RootStore, readRootDefinition)
import Kyyn.Porcelain.Capability.Tool

runToolPreparation :: (RootStore :> es, SchemaInspection :> es, GuestCompilation :> es)
  => FileTree -> Eff (ToolPreparation : es) a -> Eff es a
runToolPreparation sdk = interpret $ \_ (PrepareTools code plugins) -> runExceptT $ do
  RootDefinition _ _ _ _ declarations _ authored <- ExceptT (readRootDefinition code)
  let checked = either (throwE . pure . errorDiagnostic "tool.preparation") pure
  pluginSources <- traverse (\(name,bytes) -> (,) <$> checked (relativePath name) <*> pure bytes)
    [(name,bytes) | (path,bytes) <- files code,
      Just package <- [stripPrefix "plugins/packages/" (relativeName path)],
      Just name <- [stripPrefix "/source/src/" (dropWhile (/= '/') package)]]
  allSources <- checked (fileTree (files authored ++ pluginSources ++ files sdk))
  let interfaces = [ConnectorInterface plugin kind [(name,rootType input,rootType output) | PreparedMethod name _ input output _ <- methods]
        | PreparedPlugin (PreparedPackage plugin _ connectors) _ <- plugins, PreparedConnector kind _ _ _ _ methods <- connectors]
      bindings = [InstanceBinding binding plugin kind name | PreparedPlugin (PreparedPackage plugin _ _) instances <- plugins,
        ConfiguredConnector name binding (PreparedConnector kind _ _ _ _ _) _ <- instances]
  generated <- checked (toolBindings interfaces bindings)
  inspectionSources <- checked (fileTree (files allSources ++ generated))
  forM declarations $ \(ToolDefinition name description inputName outputName implementation) -> do
    InspectedSchema input _ <- ExceptT (inspectType inspectionSources inputName)
    InspectedSchema output _ <- ExceptT (inspectType inspectionSources outputName)
    source <- checked (toolSources interfaces bindings (rootType input) (rootType output) implementation (files allSources))
    compiled <- ExceptT (compileGuest source)
    pure (PreparedTool (ToolDescriptor name description input output) compiled plugins)
