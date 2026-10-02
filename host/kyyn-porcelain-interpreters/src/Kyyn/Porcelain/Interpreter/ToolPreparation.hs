{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation) where

import Control.Monad (forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (stripPrefix)
import Data.Bifunctor (first)
import Data.Coerce (coerce)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (rootType)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic, compilerContext)
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Domain.Plugin (QualifiedTypeName(..))
import Kyyn.Domain.Root (RootDefinition(..))
import Kyyn.Domain.Tool (ToolDefinition(..), ToolDescriptor(..))
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Porcelain.Protocol.ModelConfiguration (readModelConfiguration)
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection, InspectedSchema(..), inspectType)
import Kyyn.Plumbing.Protocol.Tool (ConnectorInterface(..), InstanceBinding(..), toolBindings, toolSources)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.RootStore (RootStore, readRootDefinition)
import Kyyn.Porcelain.Capability.Tool

runToolPreparation :: (RootStore :> es, SchemaInspection :> es, GuestCompilation :> es, DhallHandling :> es)
  => FileTree -> Eff (ToolPreparation : es) a -> Eff es a
runToolPreparation sdk = interpret $ \_ operation -> case operation of
  PrepareToolBindings code plugins -> runExceptT $ do
    (_,_,_,_,sources,names) <- environment sdk code plugins
    pure (sources,names)
  PrepareTools code plugins -> runExceptT $ do
    model <- ExceptT (readModelConfiguration code)
    (declarations,allSources,interfaces,bindings,inspectionSources,_) <- environment sdk code plugins
    forM declarations $ \(ToolDefinition name description inputName outputName implementation) -> do
      let expected = errorDiagnostic "tool.signature"
            ("Expected " ++ implementation ++ " :: " ++ coerce inputName ++ " -> Tool (Either FetchError " ++ coerce outputName ++
             "); import Tool from Kyyn.Connectors and FetchError from Kyyn.Plugin. " ++
             "Use guest module show Kyyn.Connectors for the tool entry contract.")
          withSignature :: Either [Diagnostic] a -> Either [Diagnostic] a
          withSignature = first ((expected :) . map (compilerContext "tool"))
      InspectedSchema input _ <- ExceptT (withSignature <$> inspectType inspectionSources inputName)
      InspectedSchema output _ <- ExceptT (withSignature <$> inspectType inspectionSources outputName)
      source <- checked (toolSources interfaces bindings (rootType input) (rootType output) implementation (files allSources))
      compiled <- ExceptT (withSignature <$> compileGuest source)
      pure (PreparedTool (ToolDescriptor name description input output) compiled plugins model)

environment :: RootStore :> es => FileTree -> FileTree -> [PreparedPlugin]
  -> ExceptT [Diagnostic] (Eff es) ([ToolDefinition],FileTree,[ConnectorInterface],[InstanceBinding],FileTree,[String])
environment sdk code plugins = do
  RootDefinition _ _ _ _ declarations authored <- ExceptT (readRootDefinition code)
  pluginSources <- traverse (\(name,bytes) -> (,) <$> checked (relativePath name) <*> pure bytes)
    [(name,bytes) | (path,bytes) <- files code,
      Just package <- [stripPrefix "plugins/packages/" (relativeName path)],
      Just name <- [stripPrefix "/source/src/" (dropWhile (/= '/') package)]]
  allSources <- checked (fileTree (files authored ++ pluginSources ++ files sdk))
  let interfaces = [ConnectorInterface plugin kind [(name,rootType input,rootType output) | PreparedMethod name _ input output _ <- methods]
        | PreparedPlugin (PreparedPackage plugin _ connectors) _ <- plugins, PreparedConnector {connectorType = kind, methods = methods} <- connectors]
      bindings = [InstanceBinding binding plugin kind name | PreparedPlugin (PreparedPackage plugin _ _) instances <- plugins,
        ConfiguredConnector name binding (PreparedConnector {connectorType = kind}) _ <- instances]
  generated <- checked (toolBindings interfaces bindings)
  inspectionSources <- checked (fileTree (files allSources ++ generated))
  let names = [map (\c -> if c == '/' then '.' else c) (take (length name - 3) name)
        | (path,_) <- generated, let name = relativeName path, name /= "KyynToolCalls.hs"]
  pure (declarations,allSources,interfaces,bindings,inspectionSources,names)

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "tool.preparation") pure
