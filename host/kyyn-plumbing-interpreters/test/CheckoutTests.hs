{-# LANGUAGE OverloadedStrings #-}
module CheckoutTests (checkoutTests) where

import Control.Monad (unless, when, forM_)
import qualified Data.ByteString as Bytes
import Effectful (runEff)
import Kyyn.Domain.FileTree (fileTree)
import Kyyn.Domain.Git
import Kyyn.Domain.Path
import Kyyn.Plumbing.Capability.Git
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process
import Kyyn.Plumbing.Interpreter.Git (runGit)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import System.Directory (findExecutable, createDirectoryIfMissing, doesPathExist, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

checkoutTests :: IO ()
checkoutTests = forM_ [False, True] $ \trackedDraft ->
  withSystemTempDirectory "kyyn-checkout" $ \directory -> do
    executable <- findExecutable "git" >>= maybe (fail "Git is required") pure
    scope <- either fail pure (directoryScope directory)
    let repo = Repository scope
        path = either error id . relativePath
        tree entries = either error id (fileTree [(path name,bytes) | (name,bytes) <- entries])
        perform action = runEff (runFailure (runProcessExecutionIO (runGit executable action))) >>= either (fail . show) pure
        inspect args = do
          result <- runEff . runFailure . runProcessExecutionIO $ Process.withProcess
            (Process.ProcessSpec executable args directory [("PATH",""),("LC_ALL","C")]) $ do
              Process.closeStdin
              output <- Process.collectStdout
              status <- Process.awaitExit
              pure (output,status)
          case result of
            Right (output,Process.ProcessExit 0 _) -> pure output
            _ -> fail (show result)
        command args = () <$ inspect args
        write name = Bytes.writeFile (directory </> name)
        readBytes name = Bytes.readFile (directory </> name)
        assert label condition = unless condition (fail label)
        right = either (fail . show) pure
        metadata = CommitMetadata
          (CommitIdentity "Author" "author@example.invalid" "1700000000 +0000")
          (CommitIdentity "Committer" "committer@example.invalid" "1700000001 +0000") "Accept\n"
        root = path "kb/root"
        workspace = path "kb/evolutions/e001"
        selected = [root, workspace]
    command ["init", "-q", "--ref-format=files", "-b", "main"]
    forM_ ["kb/root", "kb/evolutions/e001", "kb/evolutions/e002"] $ \name ->
      createDirectoryIfMissing True (directory </> name)
    write "kb/root/value" "old"
    write "kb/root/deleted" "obsolete fact"
    write "outside" "base"
    write ".gitignore" "ignored\n"
    command ["add", "kb/root", "outside", ".gitignore"]
    when trackedDraft $ do
      write "kb/evolutions/e001/manifest.dhall" "Draft"
      write "kb/evolutions/e001/obsolete" "obsolete draft file"
      command ["add", "kb/evolutions/e001"]
    command ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
      "-c", "commit.gpgsign=false", "commit", "-qm", "base"]
    base <- perform (resolveRevision repo "HEAD") >>= right
    branch <- perform (checkedOutBranch repo)
    assert "Checked-out branch was not resolved" (branch == Just (LocalBranch "main"))
    clean <- perform (checkoutChanges repo base [root])
    assert "Clean root reported changes" (null clean)
    write "kb/root/value" "staged"
    command ["add", "kb/root/value"]
    write "kb/root/value" "old"
    cancelled <- perform (checkoutChanges repo base [root])
    assert "Staged and working edits cancelling each other were hidden" (cancelled == [path "kb/root/value"])
    command ["add", "kb/root/value"]
    write "kb/root/ignored" "must not overwrite ignored bytes"
    ignored <- perform (checkoutChanges repo base [root])
    assert "Ignored root file was hidden" (ignored == [path "kb/root/ignored"])
    removeFile (directory </> "kb/root/ignored")
    write "kb/evolutions/e001/manifest.dhall" "Ready"
    when trackedDraft (removeFile (directory </> "kb/evolutions/e001/obsolete"))
    write "kb/evolutions/e002/manifest.dhall" "Other draft"
    write "untracked" "outside untracked"
    write "outside" "staged outside"
    command ["add", "outside"]
    staged <- inspect ["rev-parse", ":outside"]
    write "outside" "unstaged outside"
    let replacement = tree [("value", "new"), ("added", "new fact")]
        archive = tree [("manifest.dhall", "Accepted"), ("result.json", "fixed report")]
    desired <- perform (createCommit repo (GitTree [(Subtree root,replacement), (Subtree workspace,archive)]) base metadata)
    wrongHead <- perform (synchronizeCheckout repo (LocalBranch "main") desired selected)
    case wrongHead of Left _ -> pure (); _ -> fail "Synchronization ignored mismatching HEAD"
    command ["update-ref", "--no-deref", "HEAD", revisionName base]
    detached <- perform (checkedOutBranch repo)
    assert "Detached HEAD was not distinguished" (detached == Nothing)
    refused <- perform (synchronizeCheckout repo (LocalBranch "main") base selected)
    case refused of Left _ -> pure (); _ -> fail "Synchronization accepted detached HEAD"
    command ["branch", "other", revisionName base]
    command ["symbolic-ref", "HEAD", "refs/heads/other"]
    otherBranch <- perform (synchronizeCheckout repo (LocalBranch "main") base selected)
    case otherBranch of Left _ -> pure (); _ -> fail "Synchronization accepted another branch"
    ready <- readBytes "kb/evolutions/e001/manifest.dhall"
    assert "Refused synchronization changed workspace" (ready == "Ready")
    command ["symbolic-ref", "HEAD", "refs/heads/main"]
    published <- perform (compareAndSwapRef repo (LocalBranch "main") base desired)
    assert "Publication failed" (published == RefUpdated)
    write ".git/index.lock" "held"
    locked <- perform (synchronizeCheckout repo (LocalBranch "main") desired selected)
    case locked of Left _ -> pure (); _ -> fail "Index lock did not report synchronization failure"
    stillPublished <- perform (resolveRevision repo "HEAD") >>= right
    assert "Checkout failure lost accepted commit" (stillPublished == desired)
    removeFile (directory </> ".git/index.lock")
    perform (synchronizeCheckout repo (LocalBranch "main") desired selected) >>= right
    perform (synchronizeCheckout repo (LocalBranch "main") desired selected) >>= right
    changes <- perform (checkoutChanges repo desired selected)
    assert "Synchronized checkout differs from accepted commit" (null changes)
    forM_ [("kb/root/value", "new"), ("kb/root/added", "new fact"),
      ("kb/evolutions/e001/manifest.dhall", "Accepted"), ("kb/evolutions/e001/result.json", "fixed report"),
      ("outside", "unstaged outside"), ("untracked", "outside untracked"),
      ("kb/evolutions/e002/manifest.dhall", "Other draft")] $ \(name,expected) -> do
        actual <- readBytes name
        assert ("Incorrect checkout bytes: " ++ name) (actual == expected)
    forM_ ["kb/root/deleted", "kb/evolutions/e001/obsolete"] $ \name -> do
      exists <- doesPathExist (directory </> name)
      assert ("Deleted path survived: " ++ name) (not exists)
    stagedAfter <- inspect ["rev-parse", ":outside"]
    assert "Synchronization changed unrelated staged bytes" (stagedAfter == staged)
    write "kb/root/unexpected" "retain untracked bytes"
    incomplete <- perform (synchronizeCheckout repo (LocalBranch "main") desired selected)
    case incomplete of Left _ -> pure (); _ -> fail "Untracked remainder was reported as synchronized"
    retained <- readBytes "kb/root/unexpected"
    assert "Synchronization deleted untracked remainder" (retained == "retain untracked bytes")
    putStrLn ("Scoped checkout passed (tracked draft: " ++ show trackedDraft ++ ").")
