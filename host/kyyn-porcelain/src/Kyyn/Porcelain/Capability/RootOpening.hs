{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RootOpening (RootOpening(..), openCapturedRoot, loadRootAt, loadRootInputAt, openCapturedSource, loadSourceAt) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Root (Root, SourceRoot)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Git (Repository, GitRevision, TreePath)
import Kyyn.Domain.Path (RelativePath)

data RootOpening :: Effect where
  OpenCapturedSource :: FileTree -> RootOpening m (Either [Diagnostic] SourceRoot)
  LoadSourceAt :: Repository -> GitRevision -> TreePath -> RootOpening m (Either [Diagnostic] SourceRoot)
  OpenCapturedRoot :: FileTree -> RootOpening m (Either [Diagnostic] Root)
  LoadRootAt :: Repository -> GitRevision -> TreePath -> RootOpening m (Either [Diagnostic] Root)
  LoadRootInputAt :: Repository -> GitRevision -> TreePath -> RootOpening m (Either [Diagnostic] (Root, [RelativePath]))

type instance DispatchOf RootOpening = Dynamic

openCapturedSource :: RootOpening :> es => FileTree -> Eff es (Either [Diagnostic] SourceRoot)
openCapturedSource = send . OpenCapturedSource

loadSourceAt :: RootOpening :> es => Repository -> GitRevision -> TreePath -> Eff es (Either [Diagnostic] SourceRoot)
loadSourceAt repository revision = send . LoadSourceAt repository revision

openCapturedRoot :: RootOpening :> es => FileTree -> Eff es (Either [Diagnostic] Root)
openCapturedRoot = send . OpenCapturedRoot

loadRootAt :: RootOpening :> es => Repository -> GitRevision -> TreePath -> Eff es (Either [Diagnostic] Root)
loadRootAt repository revision = send . LoadRootAt repository revision

loadRootInputAt :: RootOpening :> es => Repository -> GitRevision -> TreePath
  -> Eff es (Either [Diagnostic] (Root, [RelativePath]))
loadRootInputAt repository revision = send . LoadRootInputAt repository revision
