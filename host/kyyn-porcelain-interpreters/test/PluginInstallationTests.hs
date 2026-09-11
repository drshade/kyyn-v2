{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Effectful (Eff, IOE, runEff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
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
import System.Directory (createDirectory, createDirectoryIfMissing, createFileLink, findExecutable)
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
      cases = [(empty, [], False, "plugin.manifest-missing"),
               (invalid, [], False, "plugin.manifest-invalid"),
               (withoutEntry, [], False, "plugin.entry-missing"),
               (fixture "local-file", [path "package/src/LocalFile/Plugin.hs"], False, "plugin.source-uncommitted"),
               (fixture "local-file", [], True, "plugin.already-installed")]
      revision = either error id (gitRevision (replicate 40 'a'))
      repository = Repository (scope "/source")
      kb = KnowledgeBase (Repository (scope "/target")) (Subtree (path "nested/kb"))
  forM_ cases $ \(tree, changed, exists, expected) -> do
    let gitHandler :: Eff (Git : es) a -> Eff es a
        gitHandler = interpret $ \_ -> \case
          DiscoverRepository _ -> pure (Right (repository, Subtree (path "package")))
          ResolveRevision _ "HEAD" -> pure (Right revision)
          SourceChanges _ _ _ _ -> pure changed
          ReadTreeAt _ _ _ _ -> pure (Right tree)
          _ -> error "Installation attempted a Git mutation or unexpected read"
        noWrites :: Eff (FS.FileSystem : es) a -> Eff es a
        noWrites = interpret $ \_ -> \case
          FS.EntryExists _ _ -> pure exists
          _ -> error "Refused installation performed a filesystem write"
        result = runPureEff (gitHandler (noWrites (runDhallHandling (runPluginInstallation
          (installPlugin kb (LocalPackage (scope "/source/package") WholeTree))))))
    case result of
      Left [Diagnostic _ code _ _] -> assert "wrong refusal" (code == expected)
      other -> fail (show other)

integrationTests :: IO ()
integrationTests = withSystemTempDirectory "kyyn-plugin-install-" $ \directory -> do
  executable <- findExecutable "git" >>= maybe (fail "Git required") pure
  let sourceDirectory = directory </> "source"
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
        (runFileSystemIO (scope directory) (runDhallHandling (runPluginInstallation (installPlugin kb selected))))))) >>= right
  url <- right (gitUrl ("file://" ++ sourceDirectory))
  forM_ [(LocalPackage (scope (sourceDirectory </> "packages")) (Subtree (path "local")), "local-file", LocalRepository (scope sourceDirectory), "packages/local"),
         (GitPackage url (Subtree (path "packages/remote")), "remote-file", RemoteRepository url, "packages/remote")] $ \(selection,name,originRepository,selected) -> do
    InstalledPlugin installed target origin <- install selection >>= right
    assert "installed identity/origin" (pluginNameText installed == name && origin == PluginOrigin originRepository (Subtree (path selected)) sourceCommit)
    let expected = kbDirectory </> "work/kb/root/plugins/packages" </> name
    assert "wrong nested destination" (scopePath target == expected)
    copied <- Bytes.readFile (expected </> "source/src/LocalFile/Plugin.hs")
    assert "source bytes changed" (copied == "module LocalFile.Plugin where\n")
    encoded <- Bytes.readFile (expected </> "origin.dhall")
    decoded <- right (runPureEff (runDhallHandling (decodeOrigin encoded)))
    assert "persisted origin changed" (decoded == origin)
    before <- runEff (runFailure (runFileSystemIO (scope directory) (FS.readTree (scope kbDirectory)))) >>= right
    refused <- install selection
    case refused of Left [Diagnostic _ "plugin.already-installed" _ _] -> pure (); other -> fail (show other)
    after <- runEff (runFailure (runFileSystemIO (scope directory) (FS.readTree (scope kbDirectory)))) >>= right
    assert "duplicate changed existing KB" (before == after)
  forM_ ["empty", "linked"] $ \name -> do
    let destination = kbDirectory </> "work/kb/root/plugins/packages" </> name
    if name == "empty" then createDirectory destination else createFileLink "/missing/plugin" destination
    package <- right (fileTree (files (fixture name)))
    next <- gitAction (createCommit sourceRepository (GitTree [(Subtree (path name), package)]) (Just sourceCommit) metadata)
    _ <- gitAction (compareAndSwapRef sourceRepository sourceBranch (Just sourceCommit) next)
    refused <- install (GitPackage url (Subtree (path name)))
    case refused of Left [Diagnostic _ "plugin.already-installed" _ _] -> pure (); other -> fail (show other)
    _ <- gitAction (compareAndSwapRef sourceRepository sourceBranch (Just next) sourceCommit)
    pure ()
  createDirectoryIfMissing True (sourceDirectory </> "packages/local/src")
  Bytes.writeFile (sourceDirectory </> "packages/local/src/new.hs") "untracked"
  Bytes.writeFile (sourceDirectory </> "packages/local/src/LocalFile/Plugin.hs") "changed after installation"
  dirty <- install (LocalPackage (scope (sourceDirectory </> "packages/local")) WholeTree)
  case dirty of Left [Diagnostic _ "plugin.source-uncommitted" _ _] -> pure (); other -> fail (show other)
  copiedAfter <- Bytes.readFile (kbDirectory </> "work/kb/root/plugins/packages/local-file/source/src/LocalFile/Plugin.hs")
  assert "installed copy followed source edits" (copiedAfter == "module LocalFile.Plugin where\n")
  keep <- Bytes.readFile (kbDirectory </> "work/kb/root/keep.dhall")
  unrelated <- Bytes.readFile (kbDirectory </> "unrelated")
  assert "installation overwrote existing KB/repository files" (keep == "\"keep\"" && unrelated == "unchanged")
  headAfter <- gitAction (resolveRevision kbRepository "HEAD") >>= right
  assert "installation changed KB HEAD" (headAfter == kbCommit)
