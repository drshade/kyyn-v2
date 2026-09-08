{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.WorkspaceStore (WorkspaceStore(..), readWorkspaceSnapshot, encodeWorkspaceSnapshot) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Workspace (WorkspaceSnapshot)

data WorkspaceStore :: Effect where
  ReadWorkspaceSnapshot :: FileTree -> WorkspaceStore m (Either [Diagnostic] WorkspaceSnapshot)
  EncodeWorkspaceSnapshot :: WorkspaceSnapshot -> WorkspaceStore m (Either [Diagnostic] FileTree)

type instance DispatchOf WorkspaceStore = Dynamic

readWorkspaceSnapshot :: WorkspaceStore :> es => FileTree -> Eff es (Either [Diagnostic] WorkspaceSnapshot)
readWorkspaceSnapshot = send . ReadWorkspaceSnapshot

encodeWorkspaceSnapshot :: WorkspaceStore :> es => WorkspaceSnapshot -> Eff es (Either [Diagnostic] FileTree)
encodeWorkspaceSnapshot = send . EncodeWorkspaceSnapshot
