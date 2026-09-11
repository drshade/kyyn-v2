{-# LANGUAGE DataKinds, GADTs, OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Either (isLeft)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Effectful (Eff, IOE, runEff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic(..), Severity(..), DiagnosticLocation(..))
import Kyyn.Domain.FileTree (files, fileTree)
import Kyyn.Domain.Git
import Kyyn.Domain.Path
import Kyyn.Domain.Plugin
import Kyyn.Domain.Root (pluginPackageExclusions)
import Kyyn.Plumbing.Capability.Git
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling(..))
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExecution)
import Kyyn.Plumbing.Protocol.Plugin
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.Git
import Kyyn.Plumbing.Interpreter.ProcessExecution
import System.Directory (createDirectory, createDirectoryIfMissing, doesFileExist, findExecutable)
import System.FilePath ((</>))
import System.Process (callProcess)
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
  forM_ [("./with:colon/pkg", "/work/with:colon/pkg"), ("/abs/with:colon", "/abs/with:colon")] $ \(source, expected) ->
    assert "colon in explicit local path treated as scp source"
      (pluginSource cwd source WholeTree == Right (LocalPackage (scope expected) WholeTree))
  forM_ ["git@example.org:team/repo", "ssh://example.org/repo", "http://example.org/repo", ""] $ \source ->
    assert ("accepted unsupported source " ++ source) (isLeft (pluginSource cwd source WholeTree))
  let decode = runPureEff . runDhallHandling . decodeManifest
  manifest <- right (decode "{ name = \"local-file\", entryModule = \"LocalFile.Plugin\" }")
  assert "manifest fields" (pluginNameText (manifestName manifest) == "local-file" && entryModule manifest == "LocalFile.Plugin")
  forM_ ["{ name = \"../bad\", entryModule = \"Main\" }", "{ name = \"ok\" }", "./missing.dhall", "\255"] $ \source ->
    case decode source of
      Left [Diagnostic _ "plugin.manifest-invalid" _ _] -> pure ()
      other -> fail (show other)
  let original = [Diagnostic Error "dhall.import" "Imports are not supported" (Just (SourceLocation "manifest" 1 2)),
                  Diagnostic Warning "dhall.detail" "Another detail" Nothing]
      preserved = runPureEff $ interpret (\_ operation -> case operation of
        DecodeValue {} -> pure (Left original)
        _ -> error "Manifest decoding must only decode Dhall") (decodeManifest "{}")
  assert "Dhall diagnostic messages, locations or multiplicity lost"
    (preserved == Left [Diagnostic severity "plugin.manifest-invalid" message location |
      Diagnostic severity _ message location <- original])
  url <- right (gitUrl "https://example.org/plugins.git")
  revision <- right (gitRevision (replicate 40 'a'))
  forM_ [PluginOrigin repository selected revision | repository <- [LocalRepository cwd, RemoteRepository url], selected <- [WholeTree, Subtree (path "nested/package")]] $ \origin -> do
    bytes <- right (runPureEff (runDhallHandling (encodeOrigin origin)))
    decoded <- right (runPureEff (runDhallHandling (decodeOrigin bytes)))
    assert "origin round trip" (origin == decoded)
  assert "invalid origin revision accepted" (isLeft (runPureEff (runDhallHandling
    (decodeOrigin "{ repository = < Local : Text | Git : Text >.Local \"/work\", path = None Text, revision = \"HEAD\" }"))))
  gitTests
  putStrLn "Plugin source classification, Dhall codecs, Git source changes and acquisition passed."

gitTests :: IO ()
gitTests = withSystemTempDirectory "kyyn-plugin-git-" $ \directory -> do
  executable <- findExecutable "git" >>= maybe (fail "Git required") pure
  let originPath = directory </> "origin"
      clonePath = directory </> "clone with spaces"
      perform :: Eff '[Git, ProcessExecution, Failure, IOE] a -> IO a
      perform action = runEff (runFailure (runProcessExecutionIO (runGit executable [] action))) >>= right
      metadata = CommitMetadata (CommitIdentity "Test" "test@example.invalid" "1700000000 +0000")
        (CommitIdentity "Test" "test@example.invalid" "1700000000 +0000") "Fixture"
  createDirectory originPath
  createDirectory clonePath
  (repository,_) <- perform (initializeRepository (scope originPath)) >>= right
  Just branch <- perform (checkedOutBranch repository)
  tree <- right (fileTree [(path "packages/local-file/src/Local.hs", "committed"),
    (path "packages/local-file/.gitignore", "scratch/\ntracked-ignored\n"),
    (path "packages/local-file/tracked-ignored", "tracked"),
    (path "packages/local-file/dist-newstyle/cache", "ignored"), (path "unrelated", "outside")])
  first <- perform (createCommit repository (GitTree [(WholeTree, tree)]) Nothing metadata)
  second <- perform (createCommit repository (GitTree []) (Just first) metadata)
  _ <- perform (compareAndSwapRef repository branch Nothing second)
  _ <- perform (synchronizeCheckout repository branch second [path "packages", path "unrelated"]) >>= right
  (discovered,prefix) <- perform (discoverRepository (scope (originPath </> "packages"))) >>= right
  assert "local repository discovery" (discovered == repository && prefix == Subtree (path "packages"))
  let selectedPath = case prefix of
        WholeTree -> Subtree (path "local-file")
        Subtree p -> Subtree (path (relativeName p ++ "/local-file"))
      changes = perform (sourceChanges repository second selectedPath pluginPackageExclusions)
      package = originPath </> "packages/local-file"
  assert "prefix/subdirectory combination" (selectedPath == Subtree (path "packages/local-file"))
  clean <- changes
  assert "clean source reported dirty" (null clean)
  createDirectoryIfMissing True (package </> "scratch")
  Bytes.writeFile (package </> "scratch/cache") "ignored"
  Bytes.writeFile (package </> "dist-newstyle/cache") "excluded tracked edit"
  Bytes.writeFile (package </> "dist-newstyle/new") "excluded untracked"
  Bytes.writeFile (originPath </> "unrelated") "outside edit"
  ignored <- changes
  assert "ignored/excluded/unrelated source reported dirty" (null ignored)
  residue <- perform (checkoutChanges repository second [path "packages/local-file"])
  assert "checkout synchronization stopped seeing ignored residue" (path "packages/local-file/scratch/cache" `elem` residue)
  Bytes.writeFile (package </> "dist-newstyle-extra") "untracked sibling"
  Bytes.writeFile (package </> "tracked-ignored") "tracked edit despite ignore"
  Bytes.writeFile (package </> "src/Local.hs") "staged"
  callProcess executable ["-C", originPath, "add", "--", "packages/local-file/src/Local.hs"]
  Bytes.writeFile (package </> "src/Local.hs") "committed"
  dirty <- changes
  assert "staged/unstaged cancellation or exclusions hid source changes"
    (dirty == map path ["packages/local-file/dist-newstyle-extra", "packages/local-file/src/Local.hs", "packages/local-file/tracked-ignored"])
  localOriginBytes <- right (runPureEff (runDhallHandling (encodeOrigin
    (PluginOrigin (LocalRepository (scope originPath)) selectedPath second))))
  localOrigin <- right (runPureEff (runDhallHandling (decodeOrigin localOriginBytes)))
  assert "local origin lost repository/path/revision"
    (localOrigin == PluginOrigin (LocalRepository (scope originPath)) selectedPath second)
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
  assert "Git source included working edits or exclusions" (files selected ==
    [(path ".gitignore", "scratch/\ntracked-ignored\n"), (path "src/Local.hs", "committed"), (path "tracked-ignored", "tracked")])
  originBytes <- right (runPureEff (runDhallHandling (encodeOrigin
    (PluginOrigin (RemoteRepository url) selectedPath revision))))
  fetchedOrigin <- right (runPureEff (runDhallHandling (decodeOrigin originBytes)))
  assert "remote origin lost exact fetched revision"
    (fetchedOrigin == PluginOrigin (RemoteRepository url) selectedPath second)
  repeatClone <- perform (cloneRepository url (scope clonePath))
  case repeatClone of Left [Diagnostic _ "git.clone-failed" _ _] -> pure (); other -> fail (show other)
  unchanged <- perform (resolveRevision cloned "HEAD") >>= right
  assert "failed clone changed existing clone" (unchanged == revision)
