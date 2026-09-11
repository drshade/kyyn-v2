{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.Git
  ( Git(..), readUserIdentity, discoverRepository, initializeRepository, cloneRepository, resolveRevision, readTreeAt, readTreeExcluding, readFileAt, readDirectoryAt, readCommitParents
  , createCommit, compareAndSwapRef, checkedOutBranch, checkoutChanges, synchronizeCheckout, indexPaths
  ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Git (Repository, GitRevision, TreePath, GitTree, GitUser, CommitMetadata, LocalBranch, RefUpdate)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Path (DirectoryScope, RelativePath)
import Kyyn.Domain.Plugin (GitUrl)
import Data.ByteString (ByteString)

data Git :: Effect where
  ReadUserIdentity :: Repository -> Git m (Either [Diagnostic] GitUser)
  DiscoverRepository :: DirectoryScope -> Git m (Either [Diagnostic] (Repository, TreePath))
  InitializeRepository :: DirectoryScope -> Git m (Either [Diagnostic] (Repository, TreePath))
  CloneRepository :: GitUrl -> DirectoryScope -> Git m (Either [Diagnostic] Repository)
  ResolveRevision :: Repository -> String -> Git m (Either [Diagnostic] GitRevision)
  ReadTreeAt :: Repository -> GitRevision -> TreePath -> [RelativePath] -> Git m (Either [Diagnostic] FileTree)
  ReadFileAt :: Repository -> GitRevision -> RelativePath -> Git m (Either [Diagnostic] (Maybe ByteString))
  ReadCommitParents :: Repository -> GitRevision -> Git m (Either [Diagnostic] [GitRevision])
  ReadDirectoryAt :: Repository -> GitRevision -> TreePath -> Git m (Either [Diagnostic] (Maybe [RelativePath]))
  CreateCommit :: Repository -> GitTree -> Maybe GitRevision -> CommitMetadata -> Git m GitRevision
  CompareAndSwapRef :: Repository -> LocalBranch -> Maybe GitRevision -> GitRevision -> Git m RefUpdate
  CheckedOutBranch :: Repository -> Git m (Maybe LocalBranch)
  IndexPaths :: Repository -> [RelativePath] -> Git m [RelativePath]
  CheckoutChanges :: Repository -> GitRevision -> [RelativePath] -> Git m [RelativePath]
  SynchronizeCheckout :: Repository -> LocalBranch -> GitRevision -> [RelativePath] -> Git m (Either [Diagnostic] ())

type instance DispatchOf Git = Dynamic

readUserIdentity :: Git :> es => Repository -> Eff es (Either [Diagnostic] GitUser)
readUserIdentity = send . ReadUserIdentity

discoverRepository :: Git :> es => DirectoryScope -> Eff es (Either [Diagnostic] (Repository, TreePath))
discoverRepository = send . DiscoverRepository

initializeRepository :: Git :> es => DirectoryScope -> Eff es (Either [Diagnostic] (Repository, TreePath))
initializeRepository = send . InitializeRepository

cloneRepository :: Git :> es => GitUrl -> DirectoryScope -> Eff es (Either [Diagnostic] Repository)
cloneRepository url = send . CloneRepository url

resolveRevision :: Git :> es => Repository -> String -> Eff es (Either [Diagnostic] GitRevision)
resolveRevision repo = send . ResolveRevision repo

readTreeAt :: Git :> es => Repository -> GitRevision -> TreePath -> Eff es (Either [Diagnostic] FileTree)
readTreeAt repo revision location = readTreeExcluding repo revision location []

-- Exclusions are relative to the selected tree and include descendants.
-- Excluded blobs are not loaded.
readTreeExcluding :: Git :> es => Repository -> GitRevision -> TreePath -> [RelativePath]
  -> Eff es (Either [Diagnostic] FileTree)
readTreeExcluding repo revision location = send . ReadTreeAt repo revision location

readFileAt :: Git :> es => Repository -> GitRevision -> RelativePath -> Eff es (Either [Diagnostic] (Maybe ByteString))
readFileAt repo revision = send . ReadFileAt repo revision

readCommitParents :: Git :> es => Repository -> GitRevision -> Eff es (Either [Diagnostic] [GitRevision])
readCommitParents repo = send . ReadCommitParents repo

readDirectoryAt :: Git :> es => Repository -> GitRevision -> TreePath -> Eff es (Either [Diagnostic] (Maybe [RelativePath]))
readDirectoryAt repo revision = send . ReadDirectoryAt repo revision

createCommit :: Git :> es => Repository -> GitTree -> Maybe GitRevision -> CommitMetadata -> Eff es GitRevision
createCommit repo tree parent = send . CreateCommit repo tree parent

compareAndSwapRef :: Git :> es => Repository -> LocalBranch -> Maybe GitRevision -> GitRevision -> Eff es RefUpdate
compareAndSwapRef repo branch expected = send . CompareAndSwapRef repo branch expected

checkedOutBranch :: Git :> es => Repository -> Eff es (Maybe LocalBranch)
checkedOutBranch = send . CheckedOutBranch

indexPaths :: Git :> es => Repository -> [RelativePath] -> Eff es [RelativePath]
indexPaths repo = send . IndexPaths repo

checkoutChanges :: Git :> es => Repository -> GitRevision -> [RelativePath] -> Eff es [RelativePath]
checkoutChanges repo revision = send . CheckoutChanges repo revision

synchronizeCheckout :: Git :> es => Repository -> LocalBranch -> GitRevision -> [RelativePath] -> Eff es (Either [Diagnostic] ())
synchronizeCheckout repo branch revision = send . SynchronizeCheckout repo branch revision
