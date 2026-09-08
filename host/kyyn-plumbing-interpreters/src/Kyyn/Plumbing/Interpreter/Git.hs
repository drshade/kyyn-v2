{-# LANGUAGE GADTs, LambdaCase, OverloadedStrings #-}
module Kyyn.Plumbing.Interpreter.Git (runGit) where

import Control.Monad (forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.FileTree (fileTree)
import Kyyn.Domain.Git
import Kyyn.Domain.Path
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Failure (OperationalFailure(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.Git
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process

runGit :: forall es a. (Process.ProcessExecution :> es, Failure :> es) => FilePath -> Eff (Git : es) a -> Eff es a
runGit executable = interpret $ \_ -> \case
  ResolveRevision repo name -> resolve repo name
  ReadTreeAt repo revision location -> runExceptT $ do
    _ <- ExceptT (resolve repo (revisionName revision))
    tree <- case location of
      WholeTree -> pure (revisionName revision)
      Subtree prefix -> do
        found <- successful repo ["ls-tree", "-d", "-z", revisionName revision, "--", relativeName prefix]
        if Bytes.null found then rejected "git.missing-subtree" (relativeName prefix) else pure ()
        case Char8.words (Char8.takeWhile (/= '\t') found) of
          [_, "tree", _] -> pure ()
          _ -> rejected "git.unsupported-entry" "Selected subtree is not a directory tree"
        pure (revisionName revision ++ ":" ++ relativeName prefix)
    output <- successful repo ["ls-tree", "-r", "-z", tree]
    if Bytes.null output || Bytes.last output == 0 then pure ()
      else ExceptT (broken "Unterminated Git tree response")
    let records = if Bytes.null output then [] else Char8.split '\0' (Bytes.init output)
    entries <- forM records $ \entry -> do
      let (header, rest) = Char8.break (== '\t') entry
      (oid,path) <- case Char8.words header of
        [mode, "blob", objectId] | mode `elem` ["100644", "100755"] && not (Bytes.null rest) -> do
          name <- either (rejected "git.unsupported-path" . show) (pure . Text.unpack) (Text.decodeUtf8' (Bytes.tail rest))
          path <- either (rejected "git.unsupported-path") pure (relativePath name)
          pure (Char8.unpack objectId,path)
        _ -> rejected "git.unsupported-entry" "Expected regular files; symlinks and submodules are unsupported"
      bytes <- successful repo ["cat-file", "blob", oid]
      pure (path,bytes)
    either (rejected "git.invalid-tree") pure (fileTree entries)
  where
    rejected :: String -> String -> ExceptT [Diagnostic] (Eff es) b
    rejected code message = throwE [Diagnostic code message]
    broken :: String -> Eff es b
    broken = raiseFailure . GitUnavailable
    resolve :: Repository -> String -> Eff es (Either [Diagnostic] GitRevision)
    resolve repo name = do
      (output, Process.ProcessExit status diagnostics) <- command repo ["rev-parse", "--verify", "--quiet", "--end-of-options", name ++ "^{commit}"]
      case status of
        0 -> either broken (pure . Right) (gitRevision (Char8.unpack (Char8.strip output)))
        1 -> pure (Left [Diagnostic "git.unknown-revision" name])
        _ -> broken (Char8.unpack diagnostics)
    successful :: Repository -> [String] -> ExceptT [Diagnostic] (Eff es) Bytes.ByteString
    successful repo args = ExceptT $ do
      (output, Process.ProcessExit status diagnostics) <- command repo args
      if status == 0 then pure (Right output)
        else broken (unwords args ++ ": " ++ Char8.unpack diagnostics)
    command :: Repository -> [String] -> Eff es (Bytes.ByteString, Process.ProcessExit)
    command (Repository scope) args = Process.withProcess
      (Process.ProcessSpec executable (["--no-replace-objects", "--literal-pathspecs", "-C", scopePath scope] ++ args)
        (scopePath scope) [("LC_ALL","C"),("PATH","")]) $ do
      Process.closeStdin
      output <- Process.collectStdout
      status <- Process.awaitExit
      pure (output,status)
