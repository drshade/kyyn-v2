{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.Git (Git(..), resolveRevision, readTreeAt, createCommit, compareAndSwapRef) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Git (Repository, GitRevision, TreePath, GitTree, CommitMetadata, LocalBranch, RefUpdate)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FileTree (FileTree)

data Git :: Effect where
  ResolveRevision :: Repository -> String -> Git m (Either [Diagnostic] GitRevision)
  ReadTreeAt :: Repository -> GitRevision -> TreePath -> Git m (Either [Diagnostic] FileTree)
  CreateCommit :: Repository -> GitTree -> GitRevision -> CommitMetadata -> Git m GitRevision
  CompareAndSwapRef :: Repository -> LocalBranch -> GitRevision -> GitRevision -> Git m RefUpdate

type instance DispatchOf Git = Dynamic

resolveRevision :: Git :> es => Repository -> String -> Eff es (Either [Diagnostic] GitRevision)
resolveRevision repo = send . ResolveRevision repo

readTreeAt :: Git :> es => Repository -> GitRevision -> TreePath -> Eff es (Either [Diagnostic] FileTree)
readTreeAt repo revision = send . ReadTreeAt repo revision

createCommit :: Git :> es => Repository -> GitTree -> GitRevision -> CommitMetadata -> Eff es GitRevision
createCommit repo tree parent = send . CreateCommit repo tree parent

compareAndSwapRef :: Git :> es => Repository -> LocalBranch -> GitRevision -> GitRevision -> Eff es RefUpdate
compareAndSwapRef repo branch expected = send . CompareAndSwapRef repo branch expected
