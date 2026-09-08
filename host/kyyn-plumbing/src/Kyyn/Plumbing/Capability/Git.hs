{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.Git (Git(..), resolveRevision, readTreeAt) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Git (Repository, GitRevision)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Path (RelativePath)

data Git :: Effect where
  ResolveRevision :: Repository -> String -> Git m GitRevision
  ReadTreeAt :: Repository -> GitRevision -> RelativePath -> Git m FileTree

type instance DispatchOf Git = Dynamic

resolveRevision :: Git :> es => Repository -> String -> Eff es GitRevision
resolveRevision repo = send . ResolveRevision repo

readTreeAt :: Git :> es => Repository -> GitRevision -> RelativePath -> Eff es FileTree
readTreeAt repo revision = send . ReadTreeAt repo revision
