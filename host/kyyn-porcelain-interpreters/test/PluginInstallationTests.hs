-- Source-install interpreter with refusal-recording handlers and real Git/Dhall/
-- filesystem: local/file URLs, nested KBs, origins, replacement and unchanged HEAD.
-- No guest compiler.

{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Effectful (Eff, IOE, runEff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Evolution (EvolutionWorkspace(..), evolutionId)
import Kyyn.Domain.Workspace (EvolutionState(..))
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Git
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path
import Kyyn.Domain.Plugin
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import Kyyn.Plumbing.Capability.Git
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExecution)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Git (runGit)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Protocol.Plugin (decodeOrigin)
import Kyyn.Porcelain.Capability.PluginInstallation
import Kyyn.Porcelain.Interpreter.PluginInstallation
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Evolution
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import System.Directory (createDirectory, createDirectoryIfMissing, createFileLink, createDirectoryLink, findExecutable)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

path :: String -> RelativePath
path = either error id . relativePath

scope :: String -> DirectoryScope
scope = either error id . directoryScope

workspace :: KnowledgeBase -> EvolutionWorkspace
workspace kb = EvolutionWorkspace kb (either error id (evolutionId "000001-install"))

fixture :: String -> FileTree
fixture name = either error id (fileTree
  [(path "kyyn-plugin.dhall", Char8.pack ("{ name = \"" ++ name ++ "\", entryModule = \"LocalFile.Plugin\" }"))
  ,(path "src/LocalFile/Plugin.hs", "module LocalFile.Plugin where\n")
  ,(path "README.md", "Package documentation")])

main :: IO ()
main = do
  refusalTests
  integrationTests
  putStrLn "Plugin installation refusals, nested KB copies and unchanged HEAD passed."

refusalTests :: IO ()
refusalTests = do
  let empty = either error id (fileTree [])
      withoutEntry = either error id (fileTree (filter ((/= path "src/LocalFile/Plugin.hs") . fst) (files (fixture "local-file"))))
      invalid = either error id (fileTree [(path "kyyn-plugin.dhall", "./import.dhall")])
      cases = [(empty, [], "plugin.manifest-missing"),
               (empty, [], "plugin.source-unavailable"),
               (invalid, [], "plugin.manifest-invalid"),
               (withoutEntry, [], "plugin.entry-missing"),
               (fixture "local-file", [path "package/src/LocalFile/Plugin.hs"], "plugin.source-uncommitted")]
      revision = either error id (gitRevision (replicate 40 'a'))
      repository = Repository (scope "/source")
      kb = KnowledgeBase (Repository (scope "/target")) (Subtree (path "nested/kb"))
  forM_ cases $ \(tree, changed, expected) -> do
    let gitHandler :: Eff (Git : es) a -> Eff es a
        gitHandler = interpret $ \_ -> \case
          DiscoverRepository _ | expected /= "plugin.source-unavailable" -> pure (Right (repository, Subtree (path "package")))
          ResolveRevision _ "HEAD" -> pure (Right revision)
          SourceChanges _ _ _ _ -> pure changed
          ReadTreeAt _ _ _ _ -> pure (Right tree)
          _ -> error "Installation attempted a Git mutation or unexpected read"
        noWrites :: Eff (FS.FileSystem : es) a -> Eff es a
        noWrites = interpret $ \_ -> \case
          FS.DirectoryExists directory | directory == scope "/source/package" ->
            pure (expected /= "plugin.source-unavailable")
          _ -> error "Refused installation performed a filesystem write"
        editable :: Eff (Evolution.EvolutionStore : es) a -> Eff es a
        editable = interpret $ \_ -> \case
          Evolution.ReadEvolutionState selected | selected == workspace kb -> pure (Right Draft)
          _ -> error "Unexpected evolution operation"
        result = runPureEff (gitHandler (noWrites (runDhallHandling (editable (runPluginInstallation
          (installPlugin (workspace kb) (LocalPackage (scope "/source/package") WholeTree)))))))
    case result of
      Left [Diagnostic _ code message _] -> do
        assert "wrong refusal" (code == expected)
        if code == "plugin.source-uncommitted"
          then assert "unreadable changed-path diagnostic"
            (message == "Commit plugin source changes first:\npackage/src/LocalFile/Plugin.hs")
          else pure ()
      other -> fail (show other)

integrationTests :: IO ()
integrationTests = withSystemTempDirectory "kyyn-plugin-install-" $ \directory -> do
  executable <- findExecutable "git" >>= maybe (fail "Git required") pure
  let sourceDirectory = directory </> "source:checkout"
      kbDirectory = directory </> "destination"
      gitAction :: Eff '[Git, ProcessExecution, Failure, IOE] a -> IO a
      gitAction action = runEff (runFailure (runProcessExecutionIO (runGit executable [] action))) >>= right
      metadata = CommitMetadata (CommitIdentity "Test" "test@example.invalid" "1700000000 +0000")
        (CommitIdentity "Test" "test@example.invalid" "1700000000 +0000") "Fixture"
  createDirectory sourceDirectory
  createDirectory kbDirectory
  (sourceRepository,_) <- gitAction (initializeRepository (scope sourceDirectory)) >>= right
  (kbRepository,_) <- gitAction (initializeRepository (scope kbDirectory)) >>= right
  Just sourceBranch <- gitAction (checkedOutBranch sourceRepository)
  Just kbBranch <- gitAction (checkedOutBranch kbRepository)
  sourceCommit <- gitAction (createCommit sourceRepository
    (GitTree [(Subtree (path "packages/local"), fixture "local-file"), (Subtree (path "packages/remote"), fixture "remote-file")]) Nothing metadata)
  _ <- gitAction (compareAndSwapRef sourceRepository sourceBranch Nothing sourceCommit)
  _ <- gitAction (synchronizeCheckout sourceRepository sourceBranch sourceCommit [path "packages"]) >>= right
  base <- right (fileTree [(path "work/kb/root/keep.dhall", "\"keep\""), (path "unrelated", "unchanged")])
  kbCommit <- gitAction (createCommit kbRepository (GitTree [(WholeTree, base)]) Nothing metadata)
  _ <- gitAction (compareAndSwapRef kbRepository kbBranch Nothing kbCommit)
  _ <- gitAction (synchronizeCheckout kbRepository kbBranch kbCommit [path "work", path "unrelated"]) >>= right
  let kb = KnowledgeBase kbRepository (Subtree (path "work/kb"))
      install selected = runEff (runFailure (runProcessExecutionIO (runGit executable []
        (runFileSystemIO (scope directory) (runDhallHandling (runRootStore (runWorkspaceStore (runEvolutionStore
          (runPluginInstallation (installPlugin (workspace kb) selected)))))))))) >>= right
      targetRoot = kbDirectory </> "work/kb/evolutions/000001-install/target"
  createDirectoryIfMissing True targetRoot
  Bytes.writeFile (kbDirectory </> "work/kb/evolutions/000001-install/manifest.dhall")
    (Char8.pack ("{ before.revision = \"" ++ revisionName kbCommit ++ "\", name = \"install\", explanation = \"\", state = < Draft | Ready | Accepted >.Draft, kind = < AdHoc | RecipeBased : Text >.AdHoc }"))
  url <- right (gitUrl ("file://" ++ sourceDirectory))
  Bytes.writeFile (directory </> "not-a-directory") "file"
  createFileLink (directory </> "absent") (directory </> "dangling")
  forM_ [sourceDirectory </> "absent", sourceDirectory </> "absent/", directory </> "not-a-directory", directory </> "dangling"] $ \missing -> do
    refused <- install (LocalPackage (scope missing) WholeTree)
    case refused of Left [Diagnostic _ "plugin.source-unavailable" _ _] -> pure (); other -> fail (show other)
  forM_ [(LocalPackage (scope (sourceDirectory </> "packages")) (Subtree (path "local")), "local-file", LocalRepository (scope sourceDirectory), "packages/local"),
         (GitPackage url (Subtree (path "packages/remote")), "remote-file", RemoteRepository url, "packages/remote")] $ \(selection,name,originRepository,selected) -> do
    InstalledPlugin installed target origin <- install selection >>= right
    assert "installed identity/origin" (pluginNameText installed == name && origin == PluginOrigin originRepository (Subtree (path selected)) sourceCommit)
    let expected = targetRoot </> "plugins/packages" </> name
    assert "wrong nested destination" (scopePath target == expected)
    copied <- Bytes.readFile (expected </> "source/src/LocalFile/Plugin.hs")
    assert "source bytes changed" (copied == "module LocalFile.Plugin where\n")
    encoded <- Bytes.readFile (expected </> "origin.dhall")
    decoded <- right (runPureEff (runDhallHandling (decodeOrigin encoded)))
    assert "persisted origin changed" (decoded == origin)
    before <- runEff (runFailure (runFileSystemIO (scope directory) (FS.readTree (scope kbDirectory)))) >>= right
    _ <- install selection >>= right
    after <- runEff (runFailure (runFileSystemIO (scope directory) (FS.readTree (scope kbDirectory)))) >>= right
    assert "same-revision reinstall changed existing KB" (before == after)
  _ <- install (LocalPackage (scope sourceDirectory) (Subtree (path "packages/local"))) >>= right
  createDirectoryLink sourceDirectory (directory </> "linked-source")
  _ <- install (LocalPackage (scope (directory </> "linked-source")) (Subtree (path "packages/local"))) >>= right
  forM_ ["empty"] $ \name -> do
    let destination = targetRoot </> "plugins/packages" </> name
    createDirectory destination
    package <- right (fileTree (files (fixture name)))
    next <- gitAction (createCommit sourceRepository (GitTree [(Subtree (path name), package)]) (Just sourceCommit) metadata)
    _ <- gitAction (compareAndSwapRef sourceRepository sourceBranch (Just sourceCommit) next)
    _ <- install (GitPackage url (Subtree (path name))) >>= right
    _ <- gitAction (compareAndSwapRef sourceRepository sourceBranch (Just next) sourceCommit)
    pure ()
  createDirectoryIfMissing True (sourceDirectory </> "packages/local/src")
  Bytes.writeFile (sourceDirectory </> "packages/local/src/new.hs") "untracked"
  Bytes.writeFile (sourceDirectory </> "packages/local/src/LocalFile/Plugin.hs") "changed after installation"
  dirty <- install (LocalPackage (scope (sourceDirectory </> "packages/local")) WholeTree)
  case dirty of Left [Diagnostic _ "plugin.source-uncommitted" _ _] -> pure (); other -> fail (show other)
  copiedAfter <- Bytes.readFile (targetRoot </> "plugins/packages/local-file/source/src/LocalFile/Plugin.hs")
  assert "installed copy followed source edits" (copiedAfter == "module LocalFile.Plugin where\n")
  keep <- Bytes.readFile (kbDirectory </> "work/kb/root/keep.dhall")
  unrelated <- Bytes.readFile (kbDirectory </> "unrelated")
  assert "installation overwrote existing KB/repository files" (keep == "\"keep\"" && unrelated == "unchanged")
  headAfter <- gitAction (resolveRevision kbRepository "HEAD") >>= right
  assert "installation changed KB HEAD" (headAfter == kbCommit)
