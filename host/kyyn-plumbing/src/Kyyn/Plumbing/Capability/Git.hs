{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.Git (Git(..), resolveRevision, readTreeAt) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Git (Repository, GitRevision, TreePath)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FileTree (FileTree)

data Git :: Effect where
  ResolveRevision :: Repository -> String -> Git m (Either [Diagnostic] GitRevision)
  ReadTreeAt :: Repository -> GitRevision -> TreePath -> Git m (Either [Diagnostic] FileTree)

type instance DispatchOf Git = Dynamic

resolveRevision :: Git :> es => Repository -> String -> Eff es (Either [Diagnostic] GitRevision)
resolveRevision repo = send . ResolveRevision repo

readTreeAt :: Git :> es => Repository -> GitRevision -> TreePath -> Eff es (Either [Diagnostic] FileTree)
readTreeAt repo revision = send . ReadTreeAt repo revision
