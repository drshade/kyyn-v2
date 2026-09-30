{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.PluginDiscovery (runPluginDiscovery) where

import Control.Monad (unless, when)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Char (toLower)
import Data.List (isInfixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic(..), errorDiagnostic)
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Git (Repository(..), GitRevision, TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase, knowledgeBaseScope, cacheLocation)
import Kyyn.Domain.Path (DirectoryScope, RelativePath, relativePath, directoryScope, scopedPath)
import Kyyn.Domain.Plugin
import Kyyn.Domain.Tap
import Kyyn.Domain.Root (pluginManifestLocation, pluginPackageExclusions)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import qualified Kyyn.Plumbing.Capability.Git as Git
import qualified Kyyn.Plumbing.Protocol.Tap as Protocol
import qualified Kyyn.Plumbing.Protocol.Plugin as Plugin
import Kyyn.Porcelain.Capability.PluginDiscovery

runPluginDiscovery :: (FS.FileSystem :> es, Git.Git :> es, DhallHandling :> es)
  => Eff (PluginDiscovery : es) a -> Eff es a
runPluginDiscovery = interpret $ \_ -> \case
  ListTaps kb -> runExceptT $ readTaps kb >>= traverse (\tap -> (tap,) <$> syncedRevision kb tap)
  AddTap kb tap@(Tap name _) -> runExceptT $ do
    taps <- readTaps kb
    when (any (\(Tap existing _) -> existing == name) taps) (reject "tap.exists" "Tap already exists; remove it before changing its source")
    writeTaps kb (taps ++ [tap])
  RemoveTap kb name -> runExceptT $ do
    taps <- readTaps kb
    _ <- findTap name taps
    writeTaps kb [tap | tap@(Tap existing _) <- taps, existing /= name]
  UpdateTaps kb selected -> runExceptT $ do
    taps <- readTaps kb
    chosen <- maybe (pure taps) (\name -> (:[]) <$> findTap name taps) selected
    traverse (syncTap kb) chosen
  SearchPlugins kb query -> runExceptT $ do
    taps <- readTaps kb
    entries <- concat <$> traverse (readCatalogue kb) taps
    pure [entry | entry@(AvailablePlugin (Tap tap _) _ (CatalogueEntry name description _ _)) <- entries,
      map toLower query `isInfixOf` map toLower (tapNameText tap ++ "/" ++ pluginNameText name ++ " " ++ description)]
  ResolvePlugin kb tap name -> runExceptT (findPlugin kb tap name)
  ReadAvailableGuide kb tap name -> runExceptT $ do
    AvailablePlugin selected@(Tap _ tapSource) tapRevision (CatalogueEntry expected _ source path) <- findPlugin kb tap name
    let readGuide repository revision = runExceptT $ do
          tree <- ExceptT (Git.readTreeExcluding repository revision (Subtree path) pluginPackageExclusions)
          manifestBytes <- maybe (reject "plugin.manifest-missing" "Package root has no kyyn-plugin.dhall") pure (lookup pluginManifestLocation (files tree))
          manifest <- ExceptT (Plugin.decodeManifest manifestBytes)
          unless (manifestName manifest == expected) (reject "tap.package-mismatch" "Catalogue and package names disagree")
          readme <- checked (relativePath "README.md")
          bytes <- maybe (reject "plugin.guide-missing" "This plugin has no README.md at its package root") pure (lookup readme (files tree))
          markdown <- either (const (reject "plugin.guide-invalid" "Plugin README.md must contain UTF-8 text")) pure (Text.decodeUtf8' bytes)
          pure (PluginGuide (PluginDescription manifest (PluginOrigin (RemoteRepository source) (Subtree path) revision) True) (Text.unpack markdown))
    if source == tapSource then do
      (_,repository) <- cacheScopes kb selected
      ExceptT (readGuide repository tapRevision)
    else ExceptT $ FS.withTemporaryScope $ \temporary -> runExceptT $ do
      repository <- ExceptT (Git.cloneRepository source temporary)
      revision <- ExceptT (Git.resolveRevision repository "HEAD")
      ExceptT (readGuide repository revision)

readTaps :: (FS.FileSystem :> es, DhallHandling :> es) => KnowledgeBase -> ExceptT [Diagnostic] (Eff es) [Tap]
readTaps kb = do
  scope <- checked (knowledgeBaseScope kb)
  bytes <- liftEff (FS.readOptionalBytes scope tapsPath)
  maybe (pure []) (ExceptT . Protocol.decodeTaps) bytes

syncedRevision :: (FS.FileSystem :> es, DhallHandling :> es)
  => KnowledgeBase -> Tap -> ExceptT [Diagnostic] (Eff es) (Maybe GitRevision)
syncedRevision kb tap = do
  (scope,Repository repoScope) <- cacheScopes kb tap
  present <- liftEff (FS.directoryExists repoScope)
  if not present then pure Nothing else do
    bytes <- liftEff (FS.readOptionalBytes scope syncPath)
    case bytes of
      Nothing -> pure Nothing
      Just value -> do
        (saved,revision) <- ExceptT (Protocol.decodeSync value)
        pure (if saved == tap then Just revision else Nothing)

writeTaps :: (FS.FileSystem :> es, DhallHandling :> es) => KnowledgeBase -> [Tap] -> ExceptT [Diagnostic] (Eff es) ()
writeTaps kb taps = do
  scope <- checked (knowledgeBaseScope kb)
  bytes <- ExceptT (Protocol.encodeTaps taps)
  liftEff (FS.replaceBytes scope tapsPath bytes)

findTap :: TapName -> [Tap] -> ExceptT [Diagnostic] (Eff es) Tap
findTap name taps = case [tap | tap@(Tap existing _) <- taps, existing == name] of
  [tap] -> pure tap
  _ -> reject "tap.unknown" ("Unknown tap: " ++ tapNameText name ++ "; use tap add NAME --from URL")

cacheScopes :: KnowledgeBase -> Tap -> ExceptT [Diagnostic] (Eff es) (DirectoryScope,Repository)
cacheScopes kb (Tap name _) = do
  base <- checked (knowledgeBaseScope kb)
  path <- checked (relativePath (".kyyn/taps/" ++ tapNameText name))
  scope <- checked (directoryScope (scopedPath base path))
  repoPath <- checked (relativePath "repository")
  repository <- checked (directoryScope (scopedPath scope repoPath))
  pure (scope,Repository repository)

syncTap :: (FS.FileSystem :> es, Git.Git :> es, DhallHandling :> es)
  => KnowledgeBase -> Tap -> ExceptT [Diagnostic] (Eff es) (Tap,GitRevision)
syncTap kb tap@(Tap _ source) = do
  base <- checked (knowledgeBaseScope kb)
  liftEff (FS.ensureIgnoredDirectory base cacheLocation)
  (scope,repository@(Repository repoScope)) <- cacheScopes kb tap
  liftEff (FS.ensureDirectory scope)
  gitMarker <- checked (relativePath ".git")
  exists <- liftEff (FS.entryExists repoScope gitMarker)
  let acquire action = ExceptT (fmap (either (Left . map accessHint) Right) action)
      accessHint (Diagnostic severity code message location) = Diagnostic severity code
        (message ++ "\nCheck access to the tap repository; private repositories need a configured Git credential helper.") location
  revision <- if exists then acquire (Git.fetchRevision repository source) else do
    liftEff (FS.ensureDirectory repoScope)
    cloned <- acquire (Git.cloneRepository source repoScope)
    ExceptT (Git.resolveRevision cloned "HEAD")
  bytes <- ExceptT (Git.readFileAt repository revision cataloguePath) >>= maybe
    (reject "tap.catalogue-missing" "Tap repository has no kyyn-tap.dhall") pure
  _ <- ExceptT (Protocol.decodeCatalogue bytes)
  sync <- ExceptT (Protocol.encodeSync (tap,revision))
  liftEff (FS.replaceBytes scope syncPath sync)
  pure (tap,revision)

readCatalogue :: (FS.FileSystem :> es, Git.Git :> es, DhallHandling :> es)
  => KnowledgeBase -> Tap -> ExceptT [Diagnostic] (Eff es) [AvailablePlugin]
readCatalogue kb tap@(Tap name _) = do
  (scope,repository@(Repository repoScope)) <- cacheScopes kb tap
  present <- liftEff (FS.directoryExists repoScope)
  unless present (notSynced name)
  bytes <- liftEff (FS.readOptionalBytes scope syncPath) >>= maybe (notSynced name) pure
  (saved,revision) <- ExceptT (Protocol.decodeSync bytes)
  unless (saved == tap) (notSynced name)
  catalogue <- ExceptT (Git.readFileAt repository revision cataloguePath) >>= maybe (notSynced name) pure
  entries <- ExceptT (Protocol.decodeCatalogue catalogue)
  pure (map (AvailablePlugin tap revision) entries)

findPlugin :: (FS.FileSystem :> es, Git.Git :> es, DhallHandling :> es)
  => KnowledgeBase -> TapName -> PluginName -> ExceptT [Diagnostic] (Eff es) AvailablePlugin
findPlugin kb tap name = do
  selected <- readTaps kb >>= findTap tap
  entries <- readCatalogue kb selected
  case [entry | entry@(AvailablePlugin _ _ (CatalogueEntry current _ _ _)) <- entries, current == name] of
    [entry] -> pure entry
    _ -> reject "tap.plugin-unknown" ("No plugin " ++ pluginNameText name ++ " in tap " ++ tapNameText tap)

notSynced :: TapName -> ExceptT [Diagnostic] (Eff es) a
notSynced name = reject "tap.not-synced" ("Run tap update " ++ tapNameText name ++ " to download this catalogue")

syncPath :: RelativePath
syncPath = either error id (relativePath "sync.dhall")

liftEff :: Eff es a -> ExceptT [Diagnostic] (Eff es) a
liftEff = ExceptT . fmap Right
checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (reject "tap.path-invalid") pure
reject :: String -> String -> ExceptT [Diagnostic] (Eff es) a
reject code = throwE . pure . errorDiagnostic code
