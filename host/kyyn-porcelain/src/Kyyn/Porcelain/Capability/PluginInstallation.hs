{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.PluginInstallation
  ( PluginInstallation(..), installPlugin, installNamedPlugin, preparePlugin ) where

import Data.ByteString (ByteString)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Evolution (EvolutionWorkspace)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Domain.Plugin
import Kyyn.Domain.Root (pluginSourceLocation, pluginOriginLocation)

data PluginInstallation :: Effect where
  InstallPlugin :: EvolutionWorkspace -> PluginSource -> Maybe PluginName
    -> PluginInstallation m (Either [Diagnostic] InstalledPlugin)

type instance DispatchOf PluginInstallation = Dynamic

installPlugin :: PluginInstallation :> es => EvolutionWorkspace -> PluginSource
  -> Eff es (Either [Diagnostic] InstalledPlugin)
installPlugin workspace source = send (InstallPlugin workspace source Nothing)

installNamedPlugin :: PluginInstallation :> es => EvolutionWorkspace -> PluginName -> PluginSource
  -> Eff es (Either [Diagnostic] InstalledPlugin)
installNamedPlugin workspace name source = send (InstallPlugin workspace source (Just name))

preparePlugin :: PluginManifest -> FileTree -> ByteString -> Either [Diagnostic] FileTree
preparePlugin manifest source origin = do
  entry <- checked (relativePath ("src/" ++ map modulePath (entryModule manifest) ++ ".hs"))
  case lookup entry (files source) of
    Nothing -> Left [errorDiagnostic "plugin.entry-missing" ("Missing entry source: " ++ relativeName entry)]
    Just _ -> do
      copied <- traverse (\(path, bytes) -> do
        target <- checked (relativePath (relativeName pluginSourceLocation ++ "/" ++ relativeName path))
        pure (target, bytes)) (files source)
      checked (fileTree ((pluginOriginLocation, origin) : copied))
  where
    modulePath '.' = '/'
    modulePath c = c
    checked = either (Left . pure . errorDiagnostic "plugin.path-invalid") Right
