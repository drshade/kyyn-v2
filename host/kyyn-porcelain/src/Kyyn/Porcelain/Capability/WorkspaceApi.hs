{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.WorkspaceApi (WorkspaceApi(..), inspectWorkspaceApi, inspectRootApi) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evolution (EvolutionWorkspace)
import Kyyn.Domain.GuestApi (WorkspaceCatalogue, ApiEntry, ApiSelection)
import Kyyn.Domain.Root (SourceRoot)

data WorkspaceApi :: Effect where
  InspectWorkspaceApi :: EvolutionWorkspace -> WorkspaceApi m (Either [Diagnostic] WorkspaceCatalogue)
  InspectRootApi :: SourceRoot -> ApiSelection -> WorkspaceApi m (Either [Diagnostic] [ApiEntry])
type instance DispatchOf WorkspaceApi = Dynamic

inspectWorkspaceApi :: WorkspaceApi :> es
  => EvolutionWorkspace -> Eff es (Either [Diagnostic] WorkspaceCatalogue)
inspectWorkspaceApi = send . InspectWorkspaceApi

inspectRootApi :: WorkspaceApi :> es => SourceRoot -> ApiSelection -> Eff es (Either [Diagnostic] [ApiEntry])
inspectRootApi code = send . InspectRootApi code
