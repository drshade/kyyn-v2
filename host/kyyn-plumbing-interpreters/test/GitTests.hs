{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless)
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
main = withSystemTempDirectory "kyyn-git" $ \directory -> do
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
  command ["init","-q","-b","main"]
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
  unless (Char8.length (Char8.pack (revisionName first)) == 40 || length (revisionName first) == 64) (fail "Not a full revision")
  putStrLn "Git fixed-revision byte capture, unusual paths and failure cases passed."
