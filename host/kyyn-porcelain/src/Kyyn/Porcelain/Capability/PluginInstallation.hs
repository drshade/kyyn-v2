{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.PluginInstallation
  ( PluginInstallation(..), installPlugin, preparePlugin ) where

import Data.ByteString (ByteString)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Domain.Plugin
import Kyyn.Domain.Root (pluginSourceLocation, pluginOriginLocation)

data PluginInstallation :: Effect where
  InstallPlugin :: KnowledgeBase -> PluginSource
    -> PluginInstallation m (Either [Diagnostic] InstalledPlugin)

type instance DispatchOf PluginInstallation = Dynamic

installPlugin :: PluginInstallation :> es => KnowledgeBase -> PluginSource
  -> Eff es (Either [Diagnostic] InstalledPlugin)
installPlugin kb = send . InstallPlugin kb

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
