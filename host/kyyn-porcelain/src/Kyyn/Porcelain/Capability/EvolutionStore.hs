{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvolutionStore
  ( EvolutionStore(..), captureEvolution, matchesCapturedInputs ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.Evolution (EvolutionWorkspace, EvolutionContext, CapturedEvolution)

data EvolutionStore :: Effect where
  CaptureEvolution :: EvolutionWorkspace -> EvolutionStore m (Either [Diagnostic] CapturedEvolution)
  MatchesCapturedInputs :: EvolutionContext -> EvolutionStore m (Either [Diagnostic] Bool)

type instance DispatchOf EvolutionStore = Dynamic

captureEvolution :: EvolutionStore :> es => EvolutionWorkspace -> Eff es (Either [Diagnostic] CapturedEvolution)
captureEvolution = send . CaptureEvolution

matchesCapturedInputs :: EvolutionStore :> es => EvolutionContext -> Eff es (Either [Diagnostic] Bool)
matchesCapturedInputs = send . MatchesCapturedInputs
