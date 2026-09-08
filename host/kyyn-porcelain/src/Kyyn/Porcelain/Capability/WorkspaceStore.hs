{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.WorkspaceStore (WorkspaceStore(..), readWorkspaceSnapshot) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Workspace (WorkspaceSnapshot)

data WorkspaceStore :: Effect where
  ReadWorkspaceSnapshot :: FileTree -> WorkspaceStore m (Either [Diagnostic] WorkspaceSnapshot)

type instance DispatchOf WorkspaceStore = Dynamic

readWorkspaceSnapshot :: WorkspaceStore :> es => FileTree -> Eff es (Either [Diagnostic] WorkspaceSnapshot)
readWorkspaceSnapshot = send . ReadWorkspaceSnapshot
