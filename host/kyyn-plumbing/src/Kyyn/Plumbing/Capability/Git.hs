{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.Git
  ( Git(..), resolveRevision, readTreeAt, readFileAt, readDirectoryAt, readCommitParents
  , createCommit, compareAndSwapRef, checkedOutBranch, checkoutChanges, synchronizeCheckout
  ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Git (Repository, GitRevision, TreePath, GitTree, CommitMetadata, LocalBranch, RefUpdate)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Path (RelativePath)
import Data.ByteString (ByteString)

data Git :: Effect where
  ResolveRevision :: Repository -> String -> Git m (Either [Diagnostic] GitRevision)
  ReadTreeAt :: Repository -> GitRevision -> TreePath -> Git m (Either [Diagnostic] FileTree)
  ReadFileAt :: Repository -> GitRevision -> RelativePath -> Git m (Either [Diagnostic] (Maybe ByteString))
  ReadCommitParents :: Repository -> GitRevision -> Git m (Either [Diagnostic] [GitRevision])
  ReadDirectoryAt :: Repository -> GitRevision -> TreePath -> Git m (Either [Diagnostic] (Maybe [RelativePath]))
  CreateCommit :: Repository -> GitTree -> GitRevision -> CommitMetadata -> Git m GitRevision
  CompareAndSwapRef :: Repository -> LocalBranch -> GitRevision -> GitRevision -> Git m RefUpdate
  CheckedOutBranch :: Repository -> Git m (Maybe LocalBranch)
  CheckoutChanges :: Repository -> GitRevision -> [RelativePath] -> Git m [RelativePath]
  SynchronizeCheckout :: Repository -> LocalBranch -> GitRevision -> [RelativePath] -> Git m (Either [Diagnostic] ())

type instance DispatchOf Git = Dynamic

resolveRevision :: Git :> es => Repository -> String -> Eff es (Either [Diagnostic] GitRevision)
resolveRevision repo = send . ResolveRevision repo

readTreeAt :: Git :> es => Repository -> GitRevision -> TreePath -> Eff es (Either [Diagnostic] FileTree)
readTreeAt repo revision = send . ReadTreeAt repo revision

readFileAt :: Git :> es => Repository -> GitRevision -> RelativePath -> Eff es (Either [Diagnostic] (Maybe ByteString))
readFileAt repo revision = send . ReadFileAt repo revision

readCommitParents :: Git :> es => Repository -> GitRevision -> Eff es (Either [Diagnostic] [GitRevision])
readCommitParents repo = send . ReadCommitParents repo

readDirectoryAt :: Git :> es => Repository -> GitRevision -> TreePath -> Eff es (Either [Diagnostic] (Maybe [RelativePath]))
readDirectoryAt repo revision = send . ReadDirectoryAt repo revision

createCommit :: Git :> es => Repository -> GitTree -> GitRevision -> CommitMetadata -> Eff es GitRevision
createCommit repo tree parent = send . CreateCommit repo tree parent

compareAndSwapRef :: Git :> es => Repository -> LocalBranch -> GitRevision -> GitRevision -> Eff es RefUpdate
compareAndSwapRef repo branch expected = send . CompareAndSwapRef repo branch expected

checkedOutBranch :: Git :> es => Repository -> Eff es (Maybe LocalBranch)
checkedOutBranch = send . CheckedOutBranch

checkoutChanges :: Git :> es => Repository -> GitRevision -> [RelativePath] -> Eff es [RelativePath]
checkoutChanges repo revision = send . CheckoutChanges repo revision

synchronizeCheckout :: Git :> es => Repository -> LocalBranch -> GitRevision -> [RelativePath] -> Eff es (Either [Diagnostic] ())
synchronizeCheckout repo branch revision = send . SynchronizeCheckout repo branch revision
