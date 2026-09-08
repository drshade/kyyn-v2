{-# LANGUAGE GADTs, LambdaCase, OverloadedStrings #-}
module Kyyn.Plumbing.Interpreter.Git (runGit) where

import Control.Monad (forM, foldM, unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Data.List (groupBy, sortOn, isPrefixOf, tails)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.Git
import Kyyn.Domain.Path
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.Git
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process

runGit :: forall es a. (Process.ProcessExecution :> es, Failure :> es) => FilePath -> Eff (Git : es) a -> Eff es a
runGit executable = interpret $ \_ -> \case
  ResolveRevision repo name -> resolve repo name
  ReadFileAt repo revision path -> runExceptT $ do
    _ <- ExceptT (resolve repo (revisionName revision))
    found <- successful repo ["ls-tree", "-z", revisionName revision, "--", relativeName path]
    if Bytes.null found then pure Nothing else
      case Char8.words (Char8.takeWhile (/= '\t') found) of
        [mode, "blob", objectId] | mode `elem` ["100644", "100755"] ->
          Just <$> successful repo ["cat-file", "blob", Char8.unpack objectId]
        _ -> rejected "git.unsupported-entry" "Expected a regular file"
  ReadCommitParents repo revision -> runExceptT $ do
    _ <- ExceptT (resolve repo (revisionName revision))
    commit <- successful repo ["cat-file", "commit", revisionName revision]
    let headers = takeWhile (not . Bytes.null) (Char8.lines commit)
    traverse (either (rejected "git.invalid-commit") pure . gitRevision . Char8.unpack . Bytes.drop 7)
      (filter ("parent " `Bytes.isPrefixOf`) headers)
  CreateCommit repo (GitTree replacements) parent (CommitMetadata author committer message) -> do
    let components WholeTree = []
        components (Subtree prefix) = Char8.split '/' (utf8 (relativeName prefix))
        prefixes = map (components . fst) replacements
    unless (and [not (a `isPrefixOf` b || b `isPrefixOf` a) | a:rest <- tails prefixes, b <- rest])
      (broken "Overlapping Git subtree replacements")
    _ <- resolve repo (revisionName parent) >>= either (broken . show) pure
    base <- checked repo [] ["rev-parse", revisionName parent ++ "^{tree}"] Bytes.empty
    tree <- foldM (\old (location, replacement) -> do
      replacementTree <- build repo [(Char8.split '/' (utf8 (relativeName path)), bytes) | (path,bytes) <- files replacement]
      changed <- replace repo (Just (oid old)) (components location)
        (if null (files replacement) then Nothing else Just replacementTree)
      maybe (makeTree repo []) (pure . Char8.pack) changed) base replacements
    output <- checked repo (identity "AUTHOR" author ++ identity "COMMITTER" committer)
      ["-c", "commit.gpgsign=false", "commit-tree", oid tree, "-p", revisionName parent]
      (utf8 message)
    either broken pure (gitRevision (oid output))
  CompareAndSwapRef repo (LocalBranch branch) expected desired -> do
    let ref = "refs/heads/" ++ branch
    _ <- checked repo [] ["check-ref-format", ref] Bytes.empty
    (_, Process.ProcessExit status diagnostics) <- command repo
      ["update-ref", "--no-deref", ref, revisionName desired, revisionName expected]
    if status == 0 then pure RefUpdated else do
      actual <- resolve repo ref >>= either (const (pure Nothing)) (pure . Just)
      if actual /= Just expected then pure (RefNotUpdated actual)
        else broken ("Conditional ref update failed: " ++ Char8.unpack diagnostics)
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
      (blobId,path) <- case Char8.words header of
        [mode, "blob", objectId] | mode `elem` ["100644", "100755"] && not (Bytes.null rest) -> do
          name <- either (rejected "git.unsupported-path" . show) (pure . Text.unpack) (Text.decodeUtf8' (Bytes.tail rest))
          path <- either (rejected "git.unsupported-path") pure (relativePath name)
          pure (Char8.unpack objectId,path)
        _ -> rejected "git.unsupported-entry" "Expected regular files; symlinks and submodules are unsupported"
      bytes <- successful repo ["cat-file", "blob", blobId]
      pure (path,bytes)
    either (rejected "git.invalid-tree") pure (fileTree entries)
  where
    utf8 = Text.encodeUtf8 . Text.pack
    oid = Char8.unpack . Char8.strip
    identity prefix (CommitIdentity name email date) =
      [("GIT_" ++ prefix ++ "_NAME", name), ("GIT_" ++ prefix ++ "_EMAIL", email), ("GIT_" ++ prefix ++ "_DATE", date)]
    makeTree :: Repository -> [Bytes.ByteString] -> Eff es Bytes.ByteString
    makeTree repo entries = checked repo [] ["mktree", "-z"] (Bytes.concat [entry <> "\0" | entry <- entries])
    treeEntry name object = "040000 tree " <> Char8.pack object <> "\t" <> name
    build :: Repository -> [([Bytes.ByteString], Bytes.ByteString)] -> Eff es String
    build repo entries = do
      records <- forM (groupBy (\a b -> take 1 (fst a) == take 1 (fst b)) (sortOn fst entries)) $ \group ->
        case group of
          [([name], bytes)] -> do
            object <- checked repo [] ["hash-object", "-w", "--stdin", "--no-filters"] bytes
            pure ("100644 blob " <> Char8.strip object <> "\t" <> name)
          ((name:_, _):_) -> treeEntry name <$> build repo [(drop 1 path,bytes) | (path,bytes) <- group]
          _ -> broken "Invalid replacement file tree"
      oid <$> makeTree repo records
    replace :: Repository -> Maybe String -> [Bytes.ByteString] -> Maybe String -> Eff es (Maybe String)
    replace _ _ [] replacement = pure replacement
    replace repo old (name:rest) replacement = do
      output <- maybe (pure Bytes.empty) (\object -> checked repo [] ["ls-tree", "-z", object] Bytes.empty) old
      let entries = if Bytes.null output then [] else Char8.split '\0' (Bytes.init output)
          entryName = Bytes.drop 1 . Char8.dropWhile (/= '\t')
          matching = filter ((== name) . entryName) entries
      child <- case matching of
        [] -> pure Nothing
        [entry] -> case Char8.words (Char8.takeWhile (/= '\t') entry) of
          [_, "tree", object] -> pure (Just (Char8.unpack object))
          _ | null rest -> pure Nothing
          _ -> broken "Replacement traverses a non-directory Git entry"
        _ -> broken "Duplicate Git tree entries"
      updated <- replace repo child rest replacement
      let entries' = filter ((/= name) . entryName) entries ++ maybe [] (\object -> [treeEntry name object]) updated
      if null entries' then pure Nothing else Just . oid <$> makeTree repo entries'
    checked :: Repository -> [(String,String)] -> [String] -> Bytes.ByteString -> Eff es Bytes.ByteString
    checked repo env args input = do
      (output, Process.ProcessExit status diagnostics) <- commandInput repo env args input
      if status == 0 then pure output else broken (unwords args ++ ": " ++ Char8.unpack diagnostics)
    rejected :: String -> String -> ExceptT [Diagnostic] (Eff es) b
    rejected code message = throwE [errorDiagnostic code message]
    broken :: String -> Eff es b
    broken = raiseFailure . GitUnavailable
    resolve :: Repository -> String -> Eff es (Either [Diagnostic] GitRevision)
    resolve repo name = do
      (output, Process.ProcessExit status diagnostics) <- command repo ["rev-parse", "--verify", "--quiet", "--end-of-options", name ++ "^{commit}"]
      case status of
        0 -> either broken (pure . Right) (gitRevision (Char8.unpack (Char8.strip output)))
        1 -> pure (Left [errorDiagnostic "git.unknown-revision" name])
        _ -> broken (Char8.unpack diagnostics)
    successful :: Repository -> [String] -> ExceptT [Diagnostic] (Eff es) Bytes.ByteString
    successful repo args = ExceptT $ do
      (output, Process.ProcessExit status diagnostics) <- command repo args
      if status == 0 then pure (Right output)
        else broken (unwords args ++ ": " ++ Char8.unpack diagnostics)
    command :: Repository -> [String] -> Eff es (Bytes.ByteString, Process.ProcessExit)
    command repo args = commandInput repo [] args Bytes.empty
    commandInput :: Repository -> [(String,String)] -> [String] -> Bytes.ByteString -> Eff es (Bytes.ByteString, Process.ProcessExit)
    commandInput (Repository scope) env args input = Process.withProcess
      (Process.ProcessSpec executable (["--no-replace-objects", "--literal-pathspecs", "-C", scopePath scope] ++ args)
        (scopePath scope) (env ++ [("LC_ALL","C"),("PATH","")])) $ do
      unless (Bytes.null input) (Process.writeStdin input)
      Process.closeStdin
      output <- Process.collectStdout
      status <- Process.awaitExit
      pure (output,status)
