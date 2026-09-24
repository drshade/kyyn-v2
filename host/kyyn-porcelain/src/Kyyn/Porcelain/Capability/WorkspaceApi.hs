{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.WorkspaceApi (WorkspaceApi(..), inspectWorkspaceApi, inspectToolApi) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evolution (EvolutionWorkspace)
import Kyyn.Domain.GuestApi (WorkspaceCatalogue, ApiModule)
import Kyyn.Domain.FileTree (FileTree)

data WorkspaceApi :: Effect where
  InspectWorkspaceApi :: EvolutionWorkspace -> WorkspaceApi m (Either [Diagnostic] WorkspaceCatalogue)
  InspectToolApi :: FileTree -> WorkspaceApi m (Either [Diagnostic] [ApiModule])
type instance DispatchOf WorkspaceApi = Dynamic

inspectWorkspaceApi :: WorkspaceApi :> es
  => EvolutionWorkspace -> Eff es (Either [Diagnostic] WorkspaceCatalogue)
inspectWorkspaceApi = send . InspectWorkspaceApi

inspectToolApi :: WorkspaceApi :> es => FileTree -> Eff es (Either [Diagnostic] [ApiModule])
inspectToolApi = send . InspectToolApi
