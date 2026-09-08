{-# LANGUAGE GADTs, LambdaCase, OverloadedStrings #-}
module Kyyn.Plumbing.Interpreter.Git (runGit) where

import Control.Monad (forM)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.FileTree (fileTree)
import Kyyn.Domain.Git
import Kyyn.Domain.Path
import Kyyn.Domain.Failure (OperationalFailure(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.Git
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process

runGit :: forall es a. (Process.ProcessExecution :> es, Failure :> es) => FilePath -> Eff (Git : es) a -> Eff es a
runGit executable = interpret $ \_ -> \case
  ResolveRevision repo name -> do
    output <- command repo ["rev-parse", "--verify", "--end-of-options", name ++ "^{commit}"]
    checked (gitRevision (Char8.unpack (Char8.strip output)))
  ReadTreeAt repo revision prefix -> do
    output <- command repo ["ls-tree", "-r", "-z", revisionName revision ++ ":" ++ relativeName prefix]
    if Bytes.null output || Bytes.last output == 0 then pure () else broken "Unterminated Git tree response"
    let records = if Bytes.null output then [] else Char8.split '\0' (Bytes.init output)
    entries <- forM records $ \entry -> do
      let (header, rest) = Char8.break (== '\t') entry
      (oid, path) <- case Char8.words header of
        [mode, "blob", objectId] | mode `elem` ["100644", "100755"] && not (Bytes.null rest) -> do
          name <- checked (either (Left . show) (Right . Text.unpack) (Text.decodeUtf8' (Bytes.tail rest)))
          path <- checked (relativePath name)
          hash <- checked (gitRevision (Char8.unpack objectId))
          pure (revisionName hash, path)
        _ -> broken "Expected regular files in Git subtree (symlinks and submodules are unsupported)"
      bytes <- command repo ["cat-file", "blob", oid]
      pure (path,bytes)
    checked (fileTree entries)
  where
    checked :: Either String b -> Eff es b
    checked = either broken pure
    broken :: String -> Eff es b
    broken = raiseFailure . GitUnavailable
    command :: Repository -> [String] -> Eff es Bytes.ByteString
    command (Repository scope) args = Process.withProcess
      (Process.ProcessSpec executable (["--no-replace-objects", "-C", scopePath scope] ++ args)
        (scopePath scope) [("LC_ALL","C"),("PATH","")]) $ do
      Process.closeStdin
      output <- Process.collectStdout
      Process.ProcessExit status diagnostics <- Process.awaitExit
      if status == 0 then pure output
        else raiseFailure (GitUnavailable (unwords args ++ ": " ++ Char8.unpack diagnostics))
