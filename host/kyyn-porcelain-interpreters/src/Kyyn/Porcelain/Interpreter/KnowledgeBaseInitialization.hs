{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.KnowledgeBaseInitialization (runKnowledgeBaseInitialization) where

import Control.Monad (forM_, unless, when)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (isPrefixOf)
import Data.Maybe (isJust)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic(..), errorDiagnostic)
import Kyyn.Domain.Git
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..), knowledgeBasePath)
import Kyyn.Domain.Path
import Kyyn.Domain.Publication
import Kyyn.Domain.Tap (tapsPath, firstPartyTap)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import qualified Kyyn.Plumbing.Protocol.Tap as Tap
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Porcelain.Capability.KnowledgeBaseInitialization
import qualified Kyyn.Porcelain.Capability.RootStore as Store
import System.FilePath (takeDirectory, takeFileName, makeRelative)

runKnowledgeBaseInitialization :: (FS.FileSystem :> es, Git.Git :> es, Store.RootStore :> es, DhallHandling :> es)
  => Eff (KnowledgeBaseInitialization : es) a -> Eff es a
runKnowledgeBaseInitialization = interpret $ \_ -> \case
  PrepareKnowledgeBase scope -> prepare scope
  PublishInitialRoot target@(InitializationTarget scope _ selected) metadata root -> runExceptT $ do
    current <- ExceptT (prepare scope)
    unless (current == target) (reject "kb.initialization-changed" "The target changed since initialization was prepared; retry kb init.")
    rootFiles <- ExceptT (Store.exportRootFiles root)
    (kb@(KnowledgeBase repository _), branch, parent) <- case selected of
      Just existing -> pure existing
      Nothing -> do
        liftEff (FS.ensureDirectory scope)
        (repository,prefix) <- ExceptT (Git.initializeRepository scope)
        branch <- liftEff (Git.checkedOutBranch repository) >>= maybe
          (reject "git.detached-head" "Initialization requires a checked-out branch.") pure
        parent <- liftEff (optionalHead repository)
        when (isJust parent) (reject "kb.initialization-changed" "A repository appeared during initialization; retry kb init.")
        pure (KnowledgeBase repository prefix, branch, parent)
    rootPath <- checkedPath (Store.rootLocation kb)
    existingTaps <- liftEff (FS.readOptionalBytes scope tapsPath)
    tapBytes <- maybe (ExceptT (Tap.encodeTaps [firstPartyTap])) pure existingTaps
    tapPath <- checkedPath (knowledgeBasePath kb tapsPath)
    revision <- liftEff (Git.createCommit repository (GitTreeWithFiles [(Subtree rootPath,rootFiles)] [(tapPath,tapBytes)]) parent metadata)
    actualBranch <- liftEff (Git.checkedOutBranch repository)
    unless (actualBranch == Just branch) (reject "git.detached-head" "The checked-out branch changed; initialization was not published.")
    updated <- liftEff (Git.compareAndSwapRef repository branch parent revision)
    case updated of
      RefNotUpdated _ -> reject "kb.initialization-changed" "The branch advanced; initialization was not published. Retry kb init."
      RefUpdated -> do
        synchronized <- liftEff (Git.synchronizeCheckout repository branch revision [rootPath,tapPath])
        pure (InitializedRoot revision branch kb (either WorkingTreeUpdateIncomplete (const WorkingTreeUpdated) synchronized))

prepare :: (FS.FileSystem :> es, Git.Git :> es)
  => DirectoryScope -> Eff es (Either [Diagnostic] InitializationTarget)
prepare scope = runExceptT $ do
  names <- liftEff (FS.listDirectory scope)
  when (any ((`elem` ["root","evolutions"]) . relativeName) (maybe [] id names))
    (reject "kb.already-exists" "The target contains root/ or evolutions/; initialization will not overwrite it.")
  lookupScope <- nearestDirectory scope
  discovered <- liftEff (Git.discoverRepository lookupScope)
  selected <- case discovered of
    Left [Diagnostic _ "git.no-working-tree" _ _] -> requireNoGitMetadata lookupScope >> pure Nothing
    Left diagnostics -> throwE diagnostics
    Right (repository@(Repository repositoryScope),_) -> do
      let relative = makeRelative (scopePath repositoryScope) (scopePath scope)
      prefix <- if relative == "." then pure WholeTree else Subtree <$> checkedPath (relativePath relative)
      branch <- liftEff (Git.checkedOutBranch repository) >>= maybe
        (reject "git.detached-head" "Check out a branch before initializing a KB.") pure
      parent <- liftEff (optionalHead repository)
      let kb = KnowledgeBase repository prefix
      paths <- traverse (\name -> checkedPath (relativePath name >>= knowledgeBasePath kb)) ["root","evolutions"]
      indexed <- liftEff (Git.indexPaths repository paths)
      unless (null indexed) (reject "kb.already-exists" "The index already contains root/ or evolutions/ at this target.")
      forM_ parent $ \revision -> forM_ paths $ \path -> do
        found <- ExceptT (Git.readDirectoryAt repository revision (Subtree path))
        when (isJust found) (reject "kb.already-exists" "The accepted tree already contains root/ or evolutions/ at this target.")
      pure (Just (kb,branch,parent))
  rejectNested scope selected
  pure (InitializationTarget scope lookupScope selected)
nearestDirectory :: FS.FileSystem :> es => DirectoryScope -> ExceptT [Diagnostic] (Eff es) DirectoryScope
nearestDirectory scope = do
  exists <- liftEff (FS.listDirectory scope)
  case exists of
    Just _ -> pure scope
    Nothing -> do
      let parent = takeDirectory (scopePath scope)
      when (parent == scopePath scope) (reject "kb.directory" "No existing parent directory.")
      checkedPath (directoryScope parent) >>= nearestDirectory

requireNoGitMetadata :: FS.FileSystem :> es => DirectoryScope -> ExceptT [Diagnostic] (Eff es) ()
requireNoGitMetadata scope = do
  marker <- checkedPath (relativePath ".git")
  exists <- liftEff (FS.entryExists scope marker)
  when exists
    (reject "git.repository-unavailable" "Existing .git metadata could not be opened; repair the repository before initializing a KB.")
  let parent = takeDirectory (scopePath scope)
  unless (parent == scopePath scope) (checkedPath (directoryScope parent) >>= requireNoGitMetadata)

rejectNested :: (FS.FileSystem :> es, Git.Git :> es)
  => DirectoryScope -> Maybe (KnowledgeBase, LocalBranch, Maybe GitRevision) -> ExceptT [Diagnostic] (Eff es) ()
rejectNested scope selected = walk (scopePath scope)
  where
    walk current = do
      let parent = takeDirectory current
      unless (current == parent) $ do
        when (takeFileName current `elem` ["root","evolutions"]) $ do
          owner <- checkedPath (directoryScope parent)
          manifest <- checkedPath (relativePath "root/kb.dhall")
          live <- liftEff (FS.readOptionalBytes owner manifest)
          committed <- case selected of
            Just (KnowledgeBase repository@(Repository repositoryScope) _,_,Just revision) -> do
              let relative = makeRelative (scopePath repositoryScope) parent
              if relative == ".." || "../" `isPrefixOf` relative then pure Nothing
              else do
                path <- checkedPath (relativePath ((if relative == "." then "" else relative ++ "/") ++ "root/kb.dhall"))
                ExceptT (Git.readFileAt repository revision path)
            _ -> pure Nothing
          when (isJust live || isJust committed)
            (reject "kb.nested-ownership" "A KB cannot be initialized inside another KB's root/ or evolutions/ subtree.")
        walk parent

optionalHead :: Git.Git :> es => Repository -> Eff es (Maybe GitRevision)
optionalHead repository = either (const Nothing) Just <$> Git.resolveRevision repository "HEAD"

liftEff :: Eff es a -> ExceptT e (Eff es) a
liftEff = ExceptT . fmap Right

reject :: String -> String -> ExceptT [Diagnostic] (Eff es) a
reject code = throwE . pure . errorDiagnostic code

checkedPath :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checkedPath = either (reject "kb.path") pure
