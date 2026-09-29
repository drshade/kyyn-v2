{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.PluginDocumentation (runPluginDocumentation) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution (EvolutionWorkspace(..))
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Git (Repository(..), TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..), knowledgeBasePath)
import Kyyn.Domain.Path (RelativePath, relativePath, relativeName, directoryScope, scopedPath)
import Kyyn.Domain.Plugin
import Kyyn.Domain.Root (pluginPackagesLocation, pluginOriginLocation, pluginSourceLocation, pluginManifestLocation)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import qualified Kyyn.Plumbing.Capability.Git as Git
import qualified Kyyn.Plumbing.Protocol.Plugin as Protocol
import Kyyn.Porcelain.Capability.PluginDocumentation
import Kyyn.Porcelain.Capability.EvolutionStore (workspaceLocation)

runPluginDocumentation :: (FS.FileSystem :> es, Git.Git :> es, DhallHandling :> es)
  => Eff (PluginDocumentation : es) a -> Eff es a
runPluginDocumentation = interpret $ \_ -> \case
  ListPlugins selected -> runExceptT $ do
    names <- case selected of
      AcceptedPlugins kb@(KnowledgeBase repository _) revision -> do
        path <- checked (relativePath ("root/" ++ relativeName pluginPackagesLocation) >>= knowledgeBasePath kb)
        ExceptT (Git.readDirectoryAt repository revision (Subtree path))
      EvolutionPlugins workspace@(EvolutionWorkspace (KnowledgeBase (Repository repository) _) _) -> do
        location <- checked (workspaceLocation workspace)
        path <- checked (relativePath (relativeName location ++ "/target/" ++ relativeName pluginPackagesLocation))
        scope <- checked (directoryScope (scopedPath repository path))
        liftEff (FS.listDirectory scope)
    traverse (either (reject "plugin.package-invalid") pure . pluginName . relativeName) (maybe [] id names)
  DescribePlugin selected name -> runExceptT (fst <$> loadPackage selected name)
  ReadPluginGuide selected name -> runExceptT $ do
    (description,tree) <- loadPackage selected name
    bytes <- maybe (reject "plugin.guide-missing" "This plugin has no README.md guide at its package root") pure
      (lookup guidePath (files tree))
    markdown <- either (const (reject "plugin.guide-invalid" "Plugin README.md must contain UTF-8 text")) pure (Text.decodeUtf8' bytes)
    pure (PluginGuide description (Text.unpack markdown))

loadPackage :: (FS.FileSystem :> es, Git.Git :> es, DhallHandling :> es)
  => PluginLocation -> PluginName -> ExceptT [Diagnostic] (Eff es) (PluginDescription, FileTree)
loadPackage selected name = do
  let suffix = relativeName pluginPackagesLocation ++ "/" ++ pluginNameText name
  tree <- case selected of
    AcceptedPlugins kb@(KnowledgeBase repository _) revision -> do
      path <- checked (relativePath ("root/" ++ suffix) >>= knowledgeBasePath kb)
      present <- ExceptT (Git.readDirectoryAt repository revision (Subtree path))
      unless (present /= Nothing) (reject "plugin.not-installed" ("Plugin is not installed: " ++ pluginNameText name))
      ExceptT (Git.readTreeAt repository revision (Subtree path))
    EvolutionPlugins workspace@(EvolutionWorkspace (KnowledgeBase (Repository repository) _) _) -> do
      location <- checked (workspaceLocation workspace)
      path <- checked (relativePath (relativeName location ++ "/target/" ++ suffix))
      scope <- checked (directoryScope (scopedPath repository path))
      present <- liftEff (FS.directoryExists scope)
      unless present (reject "plugin.not-installed" ("Plugin is not installed in this evolution: " ++ pluginNameText name))
      liftEff (FS.readTree scope)
  manifestPath <- checked (relativePath (relativeName pluginSourceLocation ++ "/" ++ relativeName pluginManifestLocation))
  let required path = maybe (reject "plugin.package-invalid" ("Missing package file: " ++ relativeName path)) pure (lookup path (files tree))
  manifest <- required manifestPath >>= ExceptT . Protocol.decodeManifest
  unless (manifestName manifest == name) (reject "plugin.package-invalid" "Plugin directory and manifest names disagree")
  origin <- required pluginOriginLocation >>= ExceptT . Protocol.decodeOrigin
  pure (PluginDescription manifest origin (lookup guidePath (files tree) /= Nothing),tree)

guidePath :: RelativePath
guidePath = either error id (relativePath "source/README.md")

liftEff :: Eff es a -> ExceptT [Diagnostic] (Eff es) a
liftEff = ExceptT . fmap Right

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (reject "plugin.path-invalid") pure

reject :: String -> String -> ExceptT [Diagnostic] (Eff es) a
reject code = throwE . pure . errorDiagnostic code
