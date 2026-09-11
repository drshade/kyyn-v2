{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Either (isLeft)
import Data.List (isInfixOf)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Effectful (runEff, runPureEff)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.FileTree (files, fileTree)
import Kyyn.Domain.Git
import Kyyn.Domain.Path
import Kyyn.Domain.Plugin
import Kyyn.Domain.Root (pluginPackageExclusions)
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import Kyyn.Plumbing.Capability.Git
import Kyyn.Plumbing.Protocol.Plugin
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.Git
import Kyyn.Plumbing.Interpreter.ProcessExecution
import System.Directory (createDirectory, createDirectoryIfMissing, createFileLink, doesFileExist, findExecutable)
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

main :: IO ()
main = do
  forM_ ["local-file", "files2", "2"] $ \name -> right (pluginName name) >> pure ()
  forM_ ["", "..", "../bad", "Upper", "-a", "a-", "a--b", "a/b"] $ \name ->
    assert ("accepted plugin name " ++ name) (isLeft (pluginName name))
  forM_ ["", "lower", "A..B", "A.", "A/B"] $ \entry ->
    assert ("accepted entry " ++ entry) (isLeft (pluginManifest "test" entry))
  let cwd = scope "/work"
  assert "local source classified incorrectly" (pluginSource cwd "plugins/local-file" WholeTree == Right (LocalPackage (scope "/work/plugins/local-file") WholeTree))
  forM_ ["git@example.org:team/repo", "ssh://example.org/repo", "http://example.org/repo", ""] $ \source ->
    assert ("accepted unsupported source " ++ source) (isLeft (pluginSource cwd source WholeTree))
  let decode = runPureEff . runDhallHandling . decodeManifest
  manifest <- right (decode "{ name = \"local-file\", entryModule = \"LocalFile.Plugin\" }")
  assert "manifest fields" (pluginNameText (manifestName manifest) == "local-file" && entryModule manifest == "LocalFile.Plugin")
  forM_ ["{ name = \"../bad\", entryModule = \"Main\" }", "{ name = \"ok\" }", "./missing.dhall", "\255"] $ \source ->
    case decode source of
      Left [Diagnostic _ "plugin.manifest-invalid" _ _] -> pure ()
      other -> fail (show other)
  url <- right (gitUrl "https://example.org/plugins.git")
  forM_ [LocalPackage cwd WholeTree, LocalPackage cwd (Subtree (path "nested/package")), GitPackage url WholeTree, GitPackage url (Subtree (path "p"))] $ \origin -> do
    bytes <- right (runPureEff (runDhallHandling (encodeOrigin origin)))
    decoded <- right (runPureEff (runDhallHandling (decodeOrigin bytes)))
    assert "origin round trip" (origin == decoded)
  filesystemTests
  gitTests
  putStrLn "Plugin source classification, Dhall codecs, filesystem exclusions and Git acquisition passed."

filesystemTests :: IO ()
filesystemTests = withSystemTempDirectory "kyyn-plugin-fs-" $ \directory -> do
  let package = scope directory
      perform action = runEff (runFailure (runFileSystemIO package action))
  createDirectory (directory </> "src")
  Bytes.writeFile (directory </> "src/Local.hs") "uncommitted source"
  createFileLink "/missing/excluded" (directory </> ".git")
  createDirectory (directory </> "dist-newstyle")
  createFileLink "/missing/excluded" (directory </> "dist-newstyle/cache")
  Bytes.writeFile (directory </> "dist-newstyle-extra") "keep"
  tree <- perform (FS.readSourceTree package pluginPackageExclusions) >>= right >>= right
  assert "exclusions lost source/sibling" (map (relativeName . fst) (files tree) == ["dist-newstyle-extra", "src/Local.hs"])
  createFileLink "/missing/included" (directory </> "src/linked.hs")
  refused <- perform (FS.readSourceTree package pluginPackageExclusions)
  case refused of
    Right (Left [Diagnostic _ "filesystem.unsupported-entry" message _]) -> assert "entry diagnostic omits name" ("src/linked.hs" `isInfixOf` message)
    other -> fail (show other)
  strict <- perform (FS.readTree package)
  assert "owned tree changed error mode" (isLeft strict)
  missing <- perform (FS.readSourceTree (scope (directory </> "absent")) [])
  assert "missing directory silently treated as empty" (isLeft missing)

gitTests :: IO ()
gitTests = withSystemTempDirectory "kyyn-plugin-git-" $ \directory -> do
  executable <- findExecutable "git" >>= maybe (fail "Git required") pure
  let originPath = directory </> "origin"
      clonePath = directory </> "clone with spaces"
      perform action = runEff (runFailure (runProcessExecutionIO (runGit executable [] action))) >>= right
      metadata = CommitMetadata (CommitIdentity "Test" "test@example.invalid" "1700000000 +0000")
        (CommitIdentity "Test" "test@example.invalid" "1700000000 +0000") "Fixture"
  createDirectory originPath
  createDirectory clonePath
  (repository,_) <- perform (initializeRepository (scope originPath)) >>= right
  Just branch <- perform (checkedOutBranch repository)
  tree <- right (fileTree [(path "packages/local-file/src/Local.hs", "committed"),
    (path "packages/local-file/dist-newstyle/cache", "ignored"), (path "unrelated", "outside")])
  first <- perform (createCommit repository (GitTree [(WholeTree, tree)]) Nothing metadata)
  second <- perform (createCommit repository (GitTree []) (Just first) metadata)
  _ <- perform (compareAndSwapRef repository branch Nothing second)
  createDirectoryIfMissing True (originPath </> "packages/local-file/src")
  Bytes.writeFile (originPath </> "packages/local-file/src/Local.hs") "uncommitted"
  url <- right (gitUrl ("file://" ++ originPath))
  cloned <- perform (cloneRepository url (scope clonePath)) >>= right
  revision <- perform (resolveRevision cloned "HEAD") >>= right
  assert "wrong fetched revision" (revision == second)
  shallow <- Char8.readFile (clonePath </> ".git/shallow")
  assert "clone was not shallow" (Char8.unpack shallow == revisionName revision ++ "\n")
  checkedOut <- doesFileExist (clonePath </> "unrelated")
  assert "clone checked out source" (not checkedOut)
  selected <- perform (readTreeExcluding cloned revision (Subtree (path "packages/local-file")) pluginPackageExclusions) >>= right
  assert "Git source included working edits or exclusions" (files selected == [(path "src/Local.hs", "committed")])
  repeatClone <- perform (cloneRepository url (scope clonePath))
  case repeatClone of Left [Diagnostic _ "git.clone-failed" _ _] -> pure (); other -> fail (show other)
  unchanged <- perform (resolveRevision cloned "HEAD") >>= right
  assert "failed clone changed existing clone" (unchanged == revision)
