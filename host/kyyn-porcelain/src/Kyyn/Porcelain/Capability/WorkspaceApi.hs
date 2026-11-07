{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.WorkspaceApi (WorkspaceApi(..), inspectWorkspaceApi, inspectRootApi) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evolution (EvolutionWorkspace)
import Kyyn.Domain.GuestApi (WorkspaceCatalogue, ApiEntry, ApiSelection)
import Kyyn.Domain.FileTree (FileTree)

data WorkspaceApi :: Effect where
  InspectWorkspaceApi :: EvolutionWorkspace -> ApiSelection -> WorkspaceApi m (Either [Diagnostic] WorkspaceCatalogue)
  InspectRootApi :: FileTree -> ApiSelection -> WorkspaceApi m (Either [Diagnostic] [ApiEntry])
type instance DispatchOf WorkspaceApi = Dynamic

inspectWorkspaceApi :: WorkspaceApi :> es
  => EvolutionWorkspace -> ApiSelection -> Eff es (Either [Diagnostic] WorkspaceCatalogue)
inspectWorkspaceApi workspace = send . InspectWorkspaceApi workspace

inspectRootApi :: WorkspaceApi :> es => FileTree -> ApiSelection -> Eff es (Either [Diagnostic] [ApiEntry])
inspectRootApi code = send . InspectRootApi code
