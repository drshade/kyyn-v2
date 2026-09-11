{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.WorkspaceApi (WorkspaceApi(..), inspectWorkspaceApi) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evolution (EvolutionWorkspace)
import Kyyn.Domain.GuestApi (WorkspaceCatalogue)

data WorkspaceApi :: Effect where
  InspectWorkspaceApi :: EvolutionWorkspace -> WorkspaceApi m (Either [Diagnostic] WorkspaceCatalogue)
type instance DispatchOf WorkspaceApi = Dynamic

inspectWorkspaceApi :: WorkspaceApi :> es
  => EvolutionWorkspace -> Eff es (Either [Diagnostic] WorkspaceCatalogue)
inspectWorkspaceApi = send . InspectWorkspaceApi
