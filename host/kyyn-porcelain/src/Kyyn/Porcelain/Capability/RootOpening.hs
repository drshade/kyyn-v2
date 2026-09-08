{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RootOpening (RootOpening(..), openCapturedRoot, loadRootAt) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Root (Root)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Git (Repository, GitRevision, TreePath)

data RootOpening :: Effect where
  OpenCapturedRoot :: FileTree -> RootOpening m (Either [Diagnostic] Root)
  LoadRootAt :: Repository -> GitRevision -> TreePath -> RootOpening m (Either [Diagnostic] Root)

type instance DispatchOf RootOpening = Dynamic

openCapturedRoot :: RootOpening :> es => FileTree -> Eff es (Either [Diagnostic] Root)
openCapturedRoot = send . OpenCapturedRoot

loadRootAt :: RootOpening :> es => Repository -> GitRevision -> TreePath -> Eff es (Either [Diagnostic] Root)
loadRootAt repository revision = send . LoadRootAt repository revision
