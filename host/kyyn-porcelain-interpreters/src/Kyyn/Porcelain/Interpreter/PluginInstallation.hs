{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.PluginInstallation (runPluginInstallation) where

import Control.Monad (unless, when, forM_)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (intercalate)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution (EvolutionWorkspace(..))
import Kyyn.Domain.Workspace (EvolutionState(..))
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Git (Repository(..), TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (relativePath, relativeName, directoryScope, scopedPath, scopePath)
import Kyyn.Domain.Plugin
import Kyyn.Domain.Root (pluginPackagesLocation, pluginManifestLocation, pluginPackageExclusions)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import qualified Kyyn.Plumbing.Capability.Git as Git
import qualified Kyyn.Plumbing.Protocol.Plugin as Protocol
import Kyyn.Porcelain.Capability.PluginInstallation
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Evolution

runPluginInstallation :: (FS.FileSystem :> es, Git.Git :> es, DhallHandling :> es, Evolution.EvolutionStore :> es)
  => Eff (PluginInstallation : es) a -> Eff es a
runPluginInstallation = interpret $ \_ -> \case
  InstallPlugin workspace@(EvolutionWorkspace (KnowledgeBase (Repository destination) _) _) source expected -> runExceptT $ do
    state <- ExceptT (Evolution.readEvolutionState workspace)
    when (state == Accepted) (reject "plugin.evolution-accepted" "Create a new evolution to change accepted plugins")
    workspacePath <- pathChecked (Evolution.workspaceLocation workspace)
    rootPath <- pathChecked (relativePath (relativeName workspacePath ++ "/target"))
    let acquire repository selected originRepository = runExceptT $ do
          revision <- ExceptT (Git.resolveRevision repository "HEAD")
          case originRepository of
            LocalRepository _ -> do
              changes <- liftEff (Git.sourceChanges repository revision selected pluginPackageExclusions)
              unless (null changes) (reject "plugin.source-uncommitted"
                ("Commit plugin source changes first:\n" ++ intercalate "\n" (map relativeName changes)))
            RemoteRepository _ -> pure ()
          tree <- ExceptT (Git.readTreeExcluding repository revision selected pluginPackageExclusions)
          manifestBytes <- maybe (reject "plugin.manifest-missing" "Package root has no kyyn-plugin.dhall") pure
            (lookup pluginManifestLocation (files tree))
          manifest <- ExceptT (Protocol.decodeManifest manifestBytes)
          forM_ expected $ \name -> unless (manifestName manifest == name)
            (reject "tap.package-mismatch" "Catalogue and package names disagree; no plugin was installed")
          let origin = PluginOrigin originRepository selected revision
              name = manifestName manifest
          originBytes <- ExceptT (Protocol.encodeOrigin origin)
          payload <- checked (preparePlugin manifest tree originBytes)
          parentPath <- pathChecked (relativePath (relativeName rootPath ++ "/" ++ relativeName pluginPackagesLocation))
          parent <- pathChecked (directoryScope (scopedPath destination parentPath))
          namePath <- pathChecked (relativePath (pluginNameText name))
          target <- pathChecked (directoryScope (scopedPath parent namePath))
          exists <- liftEff (FS.entryExists parent namePath)
          when exists (reject "plugin.already-installed" (pluginNameText name ++ " is already installed"))
          liftEff (FS.ensureDirectory parent)
          created <- liftEff (FS.createDirectory target)
          unless created (reject "plugin.already-installed" (pluginNameText name ++ " is already installed"))
          forM_ (files payload) $ \(path, bytes) -> liftEff (FS.writeBytes target path bytes)
          pure (InstalledPlugin name target origin)
    ExceptT $ case source of
      LocalPackage directory path -> runExceptT $ do
        exists <- liftEff (FS.directoryExists directory)
        unless exists (reject "plugin.source-unavailable" ("Plugin source is not an available directory: " ++ scopePath directory))
        (repository@(Repository root), prefix) <- ExceptT (Git.discoverRepository directory)
        selected <- pathChecked (combine prefix path)
        ExceptT (acquire repository selected (LocalRepository root))
      GitPackage url path -> FS.withTemporaryScope $ \temporary -> do
        cloned <- Git.cloneRepository url temporary
        case cloned of
          Left diagnostics -> pure (Left diagnostics)
          Right repository -> acquire repository path (RemoteRepository url)

combine :: TreePath -> TreePath -> Either String TreePath
combine WholeTree path = Right path
combine prefix WholeTree = Right prefix
combine (Subtree prefix) (Subtree path) = Subtree <$> relativePath (relativeName prefix ++ "/" ++ relativeName path)

liftEff :: Eff es a -> ExceptT [Diagnostic] (Eff es) a
liftEff = ExceptT . fmap Right

checked :: Either [Diagnostic] a -> ExceptT [Diagnostic] (Eff es) a
checked = either throwE pure

pathChecked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
pathChecked = either (reject "plugin.path-invalid") pure

reject :: String -> String -> ExceptT [Diagnostic] (Eff es) a
reject code = throwE . pure . errorDiagnostic code
