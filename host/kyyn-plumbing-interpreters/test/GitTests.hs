{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import CheckoutTests (checkoutTests)
import Control.Monad (unless)
import Control.Concurrent.Async (concurrently)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Effectful (runEff)
import Kyyn.Domain.FileTree (files, fileTree)
import Kyyn.Domain.Git
import Kyyn.Domain.Path
import Kyyn.Plumbing.Capability.Git
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process
import Kyyn.Plumbing.Interpreter.Git
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.ProcessExecution
import System.Directory (findExecutable, createDirectoryIfMissing, createFileLink)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = checkoutTests >> snapshotTests

snapshotTests :: IO ()
snapshotTests = withSystemTempDirectory "kyyn-git" $ \directory -> do
  executable <- findExecutable "git" >>= maybe (fail "Git is required for this test") pure
  scope <- either fail pure (directoryScope directory)
  let repo = Repository scope
      path = either error id . relativePath
      execute action = runEff (runFailure (runProcessExecutionIO (runGit executable action))) >>= either (fail . show) (either (fail . show) pure)
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
  command ["add","root"]
  commit
  first <- execute (resolveRevision repo "HEAD")
  whole <- execute (readTreeAt repo first WholeTree)
  unless (lookup (path ("root/" ++ filename)) (files whole) == Just bytes) (fail "Repository-root capture")
  captured <- execute (readTreeAt repo first (Subtree (path "root")))
  unless (lookup (path filename) (files captured) == Just bytes) (fail "Git capture changed bytes or paths")
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
  missing <- runEff (runFailure (runProcessExecutionIO (runGit executable (readTreeAt repo first (Subtree (path "missing"))))))
  case missing of Right (Left _) -> pure (); _ -> fail "Missing subtree accepted"
  invalid <- runEff (runFailure (runProcessExecutionIO (runGit executable (resolveRevision repo "--help"))))
  case invalid of Right (Left _) -> pure (); _ -> fail "Invalid revision accepted"
  absentRepo <- Repository <$> either fail pure (directoryScope (directory </> "missing-repository"))
  unavailable <- runEff (runFailure (runProcessExecutionIO (runGit executable (resolveRevision absentRepo "HEAD"))))
  case unavailable of Left _ -> pure (); _ -> fail "Missing repository did not remain an infrastructure failure"
  createFileLink filename (directory </> "root/link")
  command ["add","root/link"]
  commit
  linked <- execute (resolveRevision repo "HEAD")
  result <- runEff (runFailure (runProcessExecutionIO (runGit executable (readTreeAt repo linked (Subtree (path "root"))))))
  case result of Right (Left _) -> pure (); _ -> fail "Symlink silently captured as a fact"
  let perform action = runEff (runFailure (runProcessExecutionIO (runGit executable action))) >>= either (fail . show) pure
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
      changes = GitTree [(Subtree (path "root"), replacement), (Subtree (path "kb/new/root"), tree [("fact", "new")])]
  candidate <- perform (createCommit repo changes parent metadata)
  repeatCandidate <- perform (createCommit repo changes parent metadata)
  assert "Commit metadata or construction was nondeterministic" (repeatCandidate == candidate)
  unchangedHead <- execute (resolveRevision repo "HEAD")
  indexAfter <- Bytes.readFile (directory </> ".git/index")
  live <- Bytes.readFile (directory </> "outside")
  assert "Construction touched head/index/worktree" (unchangedHead == parent && indexBefore == indexAfter && live == "unstaged outside")
  opened <- execute (readTreeAt repo candidate (Subtree (path "root")))
  assert "Replacement did not remove old files or preserve new bytes" (opened == replacement)
  nested <- execute (readTreeAt repo candidate (Subtree (path "kb/new/root")))
  assert "Nested replacement failed" (nested == tree [("fact", "new")])
  outsideAfter <- inspect ["ls-tree", "-z", revisionName candidate, "--", "outside", "outside-link", "kb/archive"]
  assert "Unrelated entries or mode bits changed" (outsideBefore == outsideAfter)
  parents <- inspect ["show", "-s", "--format=%P", revisionName candidate]
  assert "Incorrect commit parent" (Char8.strip parents == Char8.pack (revisionName parent))
  commitBytes <- inspect ["cat-file", "commit", revisionName candidate]
  assert "Explicit identities/dates lost"
    ("author Author <author@example.invalid> 1700000000 +0200\n" `Bytes.isInfixOf` commitBytes &&
     "committer Committer <committer@example.invalid> 1700000001 -0300\n" `Bytes.isInfixOf` commitBytes)
  removed <- perform (createCommit repo (GitTree [(Subtree (path "root"), tree [])]) parent metadata)
  removedEntries <- inspect ["ls-tree", "-z", revisionName removed, "--", "root"]
  assert "Empty replacement did not delete subtree" (Bytes.null removedEntries)
  entire <- perform (createCommit repo (GitTree [(WholeTree, tree [])]) parent metadata)
  emptyRoot <- execute (readTreeAt repo entire WholeTree)
  assert "Empty whole-tree replacement failed" (null (files emptyRoot))
  overlap <- runEff (runFailure (runProcessExecutionIO (runGit executable
    (createCommit repo (GitTree [(WholeTree,tree []), (Subtree (path "root"),tree [])]) parent metadata))))
  case overlap of Left _ -> pure (); _ -> fail "Overlapping replacements accepted"
  collision <- runEff (runFailure (runProcessExecutionIO (runGit executable
    (createCommit repo (GitTree [(Subtree (path "outside/nested"), replacement)]) parent metadata))))
  case collision of Left _ -> pure (); _ -> fail "Replacement traversed an unrelated file"
  case gitRevision (replicate 40 '0') of Left _ -> pure (); _ -> fail "Zero ID could delete a ref"
  winner <- perform (compareAndSwapRef repo (LocalBranch "main") parent candidate)
  observed <- perform (compareAndSwapRef repo (LocalBranch "main") parent candidate)
  assert "Non-zero update exit hid the already-published desired revision" (observed == RefUpdated)
  loser <- perform (compareAndSwapRef repo (LocalBranch "main") parent removed)
  assert "Expected-head CAS did not have exactly one winner" (winner == RefUpdated && loser == RefNotUpdated (Just candidate))
  finalHead <- execute (resolveRevision repo "HEAD")
  finalIndex <- Bytes.readFile (directory </> ".git/index")
  assert "Raw CAS changed index or loser moved ref" (finalHead == candidate && finalIndex == indexBefore)
  missingRef <- perform (compareAndSwapRef repo (LocalBranch "absent") parent candidate)
  assert "Missing expected ref was created" (missingRef == RefNotUpdated Nothing)
  command ["branch", "race", revisionName parent]
  (raceA,raceB) <- concurrently
    (perform (compareAndSwapRef repo (LocalBranch "race") parent candidate))
    (perform (compareAndSwapRef repo (LocalBranch "race") parent removed))
  assert "Concurrent CAS did not have exactly one winner"
    ((raceA == RefUpdated && raceB == RefNotUpdated (Just candidate)) ||
     (raceB == RefUpdated && raceA == RefNotUpdated (Just removed)))
  invalidBranch <- runEff (runFailure (runProcessExecutionIO (runGit executable
    (compareAndSwapRef repo (LocalBranch "../main") candidate removed))))
  case invalidBranch of Left _ -> pure (); _ -> fail "Invalid branch accepted"
  command ["branch", "locked", revisionName parent]
  Bytes.writeFile (directory </> ".git/refs/heads/locked.lock") "held"
  locked <- runEff (runFailure (runProcessExecutionIO (runGit executable
    (compareAndSwapRef repo (LocalBranch "locked") parent candidate))))
  case locked of Left _ -> pure (); _ -> fail "Ref lock failure misreported as base mismatch"
  unless (Char8.length (Char8.pack (revisionName first)) == 40 || length (revisionName first) == 64) (fail "Not a full revision")
  putStrLn "Git capture, isolated commit construction, subtree replacement and conditional ref updates passed."
