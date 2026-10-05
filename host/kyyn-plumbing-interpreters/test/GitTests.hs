-- Real disposable Git repositories: discovery, revision-stable filtered capture,
-- commit construction, CAS publication and scoped checkout/recovery. No guest compiler.

{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import CheckoutTests (checkoutTests)
import Control.Monad (unless)
import Control.Concurrent.Async (concurrently)
import Control.Exception (bracket_)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Effectful (runEff)
import Kyyn.Domain.FileTree (files, fileTree)
import Kyyn.Domain.Git
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Path
import Kyyn.Plumbing.Capability.Git
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process
import Kyyn.Plumbing.Interpreter.Git
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.ProcessExecution
import System.Directory (findExecutable, createDirectoryIfMissing, createFileLink, createDirectoryLink, renameFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = identityTests >> discoveryTests >> checkoutTests >> snapshotTests >> initialCommitTests

initialCommitTests :: IO ()
initialCommitTests = withSystemTempDirectory "kyyn-git-initial" $ \directory -> do
  executable <- findExecutable "git" >>= maybe (fail "Git is required") pure
  scope <- either fail pure (directoryScope directory)
  let repo = Repository scope
      path = either error id . relativePath
      tree = either error id (fileTree [(path "kb.dhall", "empty root")])
      metadata = CommitMetadata
        (CommitIdentity "Author" "author@example.invalid" "1700000000 +0000")
        (CommitIdentity "Committer" "committer@example.invalid" "1700000000 +0000") "Initialize KB\n"
      perform action = runEff (runFailure (runProcessExecutionIO (runGit executable [] action))) >>= either (fail . show) pure
      command args = do
        result <- runEff . runFailure . runProcessExecutionIO $ Process.withProcess
          (Process.ProcessSpec executable args directory [("PATH",""),("LC_ALL","C")]) $ do
            Process.closeStdin
            output <- Process.collectStdout
            status <- Process.awaitExit
            pure (output,status)
        case result of
          Right (output,Process.ProcessExit 0 _) -> pure output
          _ -> fail (show result)
      assert label condition = unless condition (fail label)
  _ <- command ["init", "-q", "-b", "main"]
  Bytes.writeFile (directory </> "unrelated") "staged"
  _ <- command ["add", "unrelated"]
  Bytes.writeFile (directory </> "unrelated") "working"
  indexBefore <- Bytes.readFile (directory </> ".git/index")
  first <- perform (createCommit repo (GitTree [(Subtree (path "nested/root"),tree)]) Nothing metadata)
  parents <- perform (readCommitParents repo first)
  assert "Initial commit has parents" (parents == Right [])
  captured <- perform (readTreeAt repo first WholeTree)
  assert "Initial commit captured live index files"
    (captured == Right (either error id (fileTree [(path "nested/root/kb.dhall", "empty root")])))
  unpublished <- perform (resolveRevision repo "HEAD")
  case unpublished of Left _ -> pure (); _ -> fail "Construction published unborn HEAD"
  published <- perform (compareAndSwapRef repo (LocalBranch "main") Nothing first)
  assert "Could not publish unborn branch" (published == RefUpdated)
  again <- perform (compareAndSwapRef repo (LocalBranch "main") Nothing first)
  assert "Initial publication retry lost desired-head recognition" (again == RefUpdated)
  alternative <- perform (createCommit repo (GitTree []) Nothing metadata)
  refused <- perform (compareAndSwapRef repo (LocalBranch "main") Nothing alternative)
  assert "Absent-ref expectation overwrote existing branch" (refused == RefNotUpdated (Just first))
  indexAfter <- Bytes.readFile (directory </> ".git/index")
  working <- Bytes.readFile (directory </> "unrelated")
  assert "Initial construction/publication changed index/worktree" (indexBefore == indexAfter && working == "working")
  restored <- perform (synchronizeCheckout repo (LocalBranch "main") first [path "nested/root"])
  assert "Could not synchronize initial subtree" (restored == Right ())
  staged <- command ["show", ":unrelated"]
  workingAfter <- Bytes.readFile (directory </> "unrelated")
  rootFile <- Bytes.readFile (directory </> "nested/root/kb.dhall")
  assert "Initial synchronization changed unrelated staged/working files"
    (staged == "staged" && workingAfter == "working" && rootFile == "empty root")
  (a,b) <- concurrently
    (perform (compareAndSwapRef repo (LocalBranch "race") Nothing first))
    (perform (compareAndSwapRef repo (LocalBranch "race") Nothing alternative))
  assert "Absent-ref race did not have exactly one winner"
    ((a == RefUpdated && b == RefNotUpdated (Just first)) ||
     (b == RefUpdated && a == RefNotUpdated (Just alternative)))
  putStrLn "Parentless commit construction, unborn publication and scoped synchronization passed."

identityTests :: IO ()
identityTests = withSystemTempDirectory "kyyn-git-identity" $ \directory -> do
  executable <- findExecutable "git" >>= maybe (fail "Git is required") pure
  scope <- either fail pure (directoryScope directory)
  let home = directory </> "home"
      xdg = directory </> "xdg"
      environment = [("HOME",home),("XDG_CONFIG_HOME",xdg),("GIT_CONFIG_NOSYSTEM","1")]
      inspect = runEff . runFailure . runProcessExecutionIO . runGit executable environment $
        readUserIdentity (Repository scope)
      command args = do
        result <- runEff . runFailure . runProcessExecutionIO $ Process.withProcess
          (Process.ProcessSpec executable args directory (environment ++ [("PATH",""),("LC_ALL","C")])) $ do
            Process.closeStdin
            _ <- Process.collectStdout
            Process.awaitExit
        case result of Right (Process.ProcessExit 0 _) -> pure (); _ -> fail (show result)
      missing = do
        result <- inspect
        case result of Right (Left [Diagnostic _ "git.identity" _ _]) -> pure (); _ -> fail (show result)
      expect name email = do
        result <- inspect
        unless (result == Right (Right (GitUser name email))) (fail (show result))
  createDirectoryIfMissing True home
  createDirectoryIfMissing True (xdg </> "git")
  command ["init","-q","-b","main"]
  missing
  command ["config","--global","user.name","Global λ"]
  missing
  command ["config","--global","user.email","global@example.invalid"]
  expect "Global λ" "global@example.invalid"
  command ["config","--local","user.name","Repository λ"]
  expect "Repository λ" "global@example.invalid"
  let included = directory </> "included.config"
  command ["config","--file",included,"user.email","included@example.invalid"]
  command ["config","--global","include.path",included]
  expect "Repository λ" "included@example.invalid"
  let conditional = directory </> "conditional.config"
  command ["config","--file",conditional,"user.email","conditional@example.invalid"]
  command ["config","--global","includeIf.gitdir:" ++ directory ++ "/.git.path",conditional]
  expect "Repository λ" "conditional@example.invalid"
  command ["config","--local","user.name","   "]
  missing
  command ["config","--local","--unset","user.name"]
  command ["config","--global","--unset-all","user.name"]
  command ["config","--file",xdg </> "git/config","user.name","XDG λ"]
  expect "XDG λ" "conditional@example.invalid"
  command ["commit","--allow-empty","-m","Identity fixture"]
  command ["config","extensions.worktreeConfig","true"]
  let worktree = directory </> "worktree"
  command ["worktree","add","-b","secondary",worktree]
  command ["-C",worktree,"config","--worktree","user.name","Worktree λ"]
  command ["-C",worktree,"config","--worktree","user.email","worktree@example.invalid"]
  worktreeScope <- either fail pure (directoryScope worktree)
  worktreeIdentity <- runEff . runFailure . runProcessExecutionIO . runGit executable environment $
    readUserIdentity (Repository worktreeScope)
  unless (worktreeIdentity == Right (Right (GitUser "Worktree λ" "worktree@example.invalid")))
    (fail (show worktreeIdentity))
  Bytes.writeFile (directory </> ".git/config") "[invalid"
  invalid <- inspect
  case invalid of Left _ -> pure (); _ -> fail "Malformed Git configuration was not an operational failure"
  putStrLn "Configured Git identity: missing, global/XDG, local/worktree precedence, includes, Unicode and malformed config passed."

discoveryTests :: IO ()
discoveryTests = withSystemTempDirectory "kyyn-discovery" $ \directory -> do
  executable <- findExecutable "git" >>= maybe (fail "Git is required") pure
  scope <- either fail pure (directoryScope directory)
  let execute action = runEff . runFailure . runProcessExecutionIO . runGit executable [] $ action
      command args = do
        result <- runEff . runFailure . runProcessExecutionIO $ Process.withProcess
          (Process.ProcessSpec executable args directory [("PATH",""),("LC_ALL","C")]) $ do
            Process.closeStdin
            _ <- Process.collectStdout
            Process.awaitExit
        case result of Right (Process.ProcessExit 0 _) -> pure (); _ -> fail (show result)
  absent <- execute (discoverRepository scope)
  case absent of Right (Left [Diagnostic _ "git.no-working-tree" _ _]) -> pure (); _ -> fail ("Non-repo was not a diagnostic: " ++ show absent)
  command ["init","-q","-b","main"]
  top <- execute (discoverRepository scope)
  unless (top == Right (Right (Repository scope, WholeTree))) (fail ("Top-level discovery: " ++ show top))
  let nestedName = "knowledge/sales \955"
  createDirectoryIfMissing True (directory </> nestedName)
  nested <- either fail pure (directoryScope (directory </> nestedName))
  expected <- either fail pure (relativePath nestedName)
  found <- execute (discoverRepository nested)
  unless (found == Right (Right (Repository scope, Subtree expected))) (fail ("Nested discovery: " ++ show found))
  createDirectoryLink (directory </> nestedName) (directory </> "linked-subtree")
  linked <- either fail pure (directoryScope (directory </> "linked-subtree"))
  linkedResult <- execute (discoverRepository linked)
  unless (linkedResult == Right (Right (Repository scope, Subtree expected)))
    (fail ("Symlinked scope discovery: " ++ show linkedResult))
  command ["init","--bare","-q","bare.git"]
  bare <- either fail pure (directoryScope (directory </> "bare.git"))
  bareResult <- execute (discoverRepository bare)
  case bareResult of Right (Left [Diagnostic _ "git.repository-unavailable" _ _]) -> pure (); _ -> fail ("Bare discovery: " ++ show bareResult)
  bareConfig <- Bytes.readFile (directory </> "bare.git/config")
  refusedBare <- execute (initializeRepository bare)
  unless (refusedBare == bareResult) (fail "Initialization did not refuse the bare repository")
  bareConfigAfter <- Bytes.readFile (directory </> "bare.git/config")
  unless (bareConfigAfter == bareConfig) (fail "Initialization modified bare repository configuration")
  unavailable <- either fail pure (directoryScope (directory </> "missing"))
  missing <- execute (discoverRepository unavailable)
  case missing of Left _ -> pure (); _ -> fail "Missing cwd was not an operational failure"
  noExecutable <- runEff . runFailure . runProcessExecutionIO . runGit (directory </> "missing-git") [] $
    discoverRepository scope
  case noExecutable of Left _ -> pure (); _ -> fail "Missing executable was not an operational failure"
  putStrLn "Repository discovery passed for root, nested, symlinked, absent and bare repositories."

snapshotTests :: IO ()
snapshotTests = withSystemTempDirectory "kyyn-git" $ \directory -> do
  executable <- findExecutable "git" >>= maybe (fail "Git is required for this test") pure
  scope <- either fail pure (directoryScope directory)
  let repo = Repository scope
      path = either error id . relativePath
      execute action = runEff (runFailure (runProcessExecutionIO (runGit executable [] action))) >>= either (fail . show) (either (fail . show) pure)
      inspect args = do
        result <- runEff . runFailure . runProcessExecutionIO $ Process.withProcess
          (Process.ProcessSpec executable args directory
            [("PATH",""),("LC_ALL","C"),("GIT_CONFIG_NOSYSTEM","1")]) $ do
            Process.closeStdin
            output <- Process.collectStdout
            exit <- Process.awaitExit
            pure (output,exit)
        case result of
          Right (output,Process.ProcessExit 0 _) -> pure output
          _ -> fail (show result)
      command args = () <$ inspect args
      commit = command ["-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","fixture"]
  command ["init","-q","--ref-format=files","-b","main"]
  createDirectoryIfMissing True (directory </> "root/nested")
  let bytes = Bytes.pack [0..255]
      filename = "nested/spaces\tand\nlines.bin"
  Bytes.writeFile (directory </> "root" </> filename) bytes
  createDirectoryIfMissing True (directory </> "root/facts")
  createDirectoryIfMissing True (directory </> "root/facts-extra")
  Bytes.writeFile (directory </> "root/facts/item") "excluded fact blob"
  Bytes.writeFile (directory </> "root/facts-extra/item") "retained neighbour"
  command ["add","root"]
  commit
  first <- execute (resolveRevision repo "HEAD")
  whole <- execute (readTreeAt repo first WholeTree)
  unless (lookup (path ("root/" ++ filename)) (files whole) == Just bytes) (fail "Repository-root capture")
  captured <- execute (readTreeAt repo first (Subtree (path "root")))
  unless (lookup (path filename) (files captured) == Just bytes) (fail "Git capture changed bytes or paths")
  factObject <- Char8.unpack . Char8.takeWhile (/= '\n') <$> inspect ["rev-parse", "HEAD:root/facts/item"]
  let objectPath = directory </> ".git/objects" </> take 2 factObject </> drop 2 factObject
      savedObject = objectPath ++ ".saved"
  bracket_ (renameFile objectPath savedObject) (renameFile savedObject objectPath) $ do
    source <- execute (readTreeExcluding repo first (Subtree (path "root")) [path "facts"])
    unless (files source == filter ((/= path "facts/item") . fst) (files captured))
      (fail "Exclusion read the missing fact blob or dropped a neighbouring path")
    unfiltered <- runEff . runFailure . runProcessExecutionIO . runGit executable [] $
      readTreeAt repo first (Subtree (path "root"))
    case unfiltered of
      Right (Right _) -> fail "Missing-blob proof did not fail without the exclusion"
      _ -> pure ()
  Bytes.writeFile (directory </> "root" </> filename) "changed"
  command ["add","root"]
  commit
  second <- execute (resolveRevision repo "refs/heads/main")
  unless (first /= second) (fail "Revision did not change")
  Bytes.writeFile (directory </> "root" </> filename) "uncommitted"
  old <- execute (readTreeAt repo first (Subtree (path "root")))
  current <- execute (readTreeAt repo second (Subtree (path "root")))
  unless (old == captured && lookup (path filename) (files current) == Just "changed")
    (fail "Fixed revision capture read live files")
  missing <- runEff (runFailure (runProcessExecutionIO (runGit executable [] (readTreeAt repo first (Subtree (path "missing"))))))
  case missing of Right (Left _) -> pure (); _ -> fail "Missing subtree accepted"
  invalid <- runEff (runFailure (runProcessExecutionIO (runGit executable [] (resolveRevision repo "--help"))))
  case invalid of Right (Left _) -> pure (); _ -> fail "Invalid revision accepted"
  absentRepo <- Repository <$> either fail pure (directoryScope (directory </> "missing-repository"))
  unavailable <- runEff (runFailure (runProcessExecutionIO (runGit executable [] (resolveRevision absentRepo "HEAD"))))
  case unavailable of Left _ -> pure (); _ -> fail "Missing repository did not remain an infrastructure failure"
  createFileLink filename (directory </> "root/link")
  command ["add","root/link"]
  commit
  linked <- execute (resolveRevision repo "HEAD")
  result <- runEff (runFailure (runProcessExecutionIO (runGit executable [] (readTreeAt repo linked (Subtree (path "root"))))))
  case result of Right (Left _) -> pure (); _ -> fail "Symlink silently captured as a fact"
  let perform action = runEff (runFailure (runProcessExecutionIO (runGit executable [] action))) >>= either (fail . show) pure
      tree entries = either error id (fileTree [(path name,content) | (name,content) <- entries])
      metadata = CommitMetadata
        (CommitIdentity "Author" "author@example.invalid" "1700000000 +0200")
        (CommitIdentity "Committer" "committer@example.invalid" "1700000001 -0300")
        "Explicit publication\n"
      assert label condition = unless condition (fail label)
  Bytes.writeFile (directory </> "outside") "committed outside"
  createFileLink "outside" (directory </> "outside-link")
  createDirectoryIfMissing True (directory </> "kb/archive")
  Bytes.writeFile (directory </> "kb/archive/old") "retained"
  command ["add", "outside", "outside-link", "kb"]
  command ["update-index", "--chmod=+x", "outside"]
  commit
  parent <- execute (resolveRevision repo "HEAD")
  Bytes.writeFile (directory </> "outside") "staged outside"
  command ["add", "outside"]
  Bytes.writeFile (directory </> "outside") "unstaged outside"
  indexBefore <- Bytes.readFile (directory </> ".git/index")
  outsideBefore <- inspect ["ls-tree", "-z", revisionName parent, "--", "outside", "outside-link", "kb/archive"]
  let replacement = tree [("nested/new\t\n\955.dhall", bytes), ("changed.dhall", "replacement")]
      changes = GitTreeWithFiles [(Subtree (path "root"), replacement), (Subtree (path "kb/new/root"), tree [("fact", "new")])]
        [(path "kb/new/taps.dhall", "tap declarations")]
  candidate <- perform (createCommit repo changes (Just parent) metadata)
  repeatCandidate <- perform (createCommit repo changes (Just parent) metadata)
  assert "Commit metadata or construction was nondeterministic" (repeatCandidate == candidate)
  unchangedHead <- execute (resolveRevision repo "HEAD")
  indexAfter <- Bytes.readFile (directory </> ".git/index")
  live <- Bytes.readFile (directory </> "outside")
  assert "Construction touched head/index/worktree" (unchangedHead == parent && indexBefore == indexAfter && live == "unstaged outside")
  opened <- execute (readTreeAt repo candidate (Subtree (path "root")))
  assert "Replacement did not remove old files or preserve new bytes" (opened == replacement)
  nested <- execute (readTreeAt repo candidate (Subtree (path "kb/new/root")))
  assert "Nested replacement failed" (nested == tree [("fact", "new")])
  tapBytes <- execute (readFileAt repo candidate (path "kb/new/taps.dhall"))
  assert "Mixed blob/tree update lost the file" (tapBytes == Just "tap declarations")
  fileOverlap <- runEff (runFailure (runProcessExecutionIO (runGit executable []
    (createCommit repo (GitTreeWithFiles [(Subtree (path "root"),replacement)] [(path "root/taps.dhall","overlap")]) (Just parent) metadata))))
  case fileOverlap of Left _ -> pure (); _ -> fail "Overlapping blob/tree replacements accepted"
  outsideAfter <- inspect ["ls-tree", "-z", revisionName candidate, "--", "outside", "outside-link", "kb/archive"]
  assert "Unrelated entries or mode bits changed" (outsideBefore == outsideAfter)
  parents <- inspect ["show", "-s", "--format=%P", revisionName candidate]
  assert "Incorrect commit parent" (Char8.strip parents == Char8.pack (revisionName parent))
  commitBytes <- inspect ["cat-file", "commit", revisionName candidate]
  assert "Explicit identities/dates lost"
    ("author Author <author@example.invalid> 1700000000 +0200\n" `Bytes.isInfixOf` commitBytes &&
     "committer Committer <committer@example.invalid> 1700000001 -0300\n" `Bytes.isInfixOf` commitBytes)
  removed <- perform (createCommit repo (GitTree [(Subtree (path "root"), tree [])]) (Just parent) metadata)
  removedEntries <- inspect ["ls-tree", "-z", revisionName removed, "--", "root"]
  assert "Empty replacement did not delete subtree" (Bytes.null removedEntries)
  entire <- perform (createCommit repo (GitTree [(WholeTree, tree [])]) (Just parent) metadata)
  emptyRoot <- execute (readTreeAt repo entire WholeTree)
  assert "Empty whole-tree replacement failed" (null (files emptyRoot))
  overlap <- runEff (runFailure (runProcessExecutionIO (runGit executable []
    (createCommit repo (GitTree [(WholeTree,tree []), (Subtree (path "root"),tree [])]) (Just parent) metadata))))
  case overlap of Left _ -> pure (); _ -> fail "Overlapping replacements accepted"
  collision <- runEff (runFailure (runProcessExecutionIO (runGit executable []
    (createCommit repo (GitTree [(Subtree (path "outside/nested"), replacement)]) (Just parent) metadata))))
  case collision of Left _ -> pure (); _ -> fail "Replacement traversed an unrelated file"
  case gitRevision (replicate 40 '0') of Left _ -> pure (); _ -> fail "Zero ID could delete a ref"
  winner <- perform (compareAndSwapRef repo (LocalBranch "main") (Just parent) candidate)
  observed <- perform (compareAndSwapRef repo (LocalBranch "main") (Just parent) candidate)
  assert "Non-zero update exit hid the already-published desired revision" (observed == RefUpdated)
  loser <- perform (compareAndSwapRef repo (LocalBranch "main") (Just parent) removed)
  assert "Expected-head CAS did not have exactly one winner" (winner == RefUpdated && loser == RefNotUpdated (Just candidate))
  finalHead <- execute (resolveRevision repo "HEAD")
  finalIndex <- Bytes.readFile (directory </> ".git/index")
  assert "Raw CAS changed index or loser moved ref" (finalHead == candidate && finalIndex == indexBefore)
  missingRef <- perform (compareAndSwapRef repo (LocalBranch "absent") (Just parent) candidate)
  assert "Missing expected ref was created" (missingRef == RefNotUpdated Nothing)
  command ["branch", "race", revisionName parent]
  (raceA,raceB) <- concurrently
    (perform (compareAndSwapRef repo (LocalBranch "race") (Just parent) candidate))
    (perform (compareAndSwapRef repo (LocalBranch "race") (Just parent) removed))
  assert "Concurrent CAS did not have exactly one winner"
    ((raceA == RefUpdated && raceB == RefNotUpdated (Just candidate)) ||
     (raceB == RefUpdated && raceA == RefNotUpdated (Just removed)))
  invalidBranch <- runEff (runFailure (runProcessExecutionIO (runGit executable []
    (compareAndSwapRef repo (LocalBranch "../main") (Just candidate) removed))))
  case invalidBranch of Left _ -> pure (); _ -> fail "Invalid branch accepted"
  command ["branch", "locked", revisionName parent]
  Bytes.writeFile (directory </> ".git/refs/heads/locked.lock") "held"
  locked <- runEff (runFailure (runProcessExecutionIO (runGit executable []
    (compareAndSwapRef repo (LocalBranch "locked") (Just parent) candidate))))
  case locked of Left _ -> pure (); _ -> fail "Ref lock failure misreported as base mismatch"
  unless (Char8.length (Char8.pack (revisionName first)) == 40 || length (revisionName first) == 64) (fail "Not a full revision")
  putStrLn "Git capture, isolated commit construction, subtree replacement and conditional ref updates passed."
