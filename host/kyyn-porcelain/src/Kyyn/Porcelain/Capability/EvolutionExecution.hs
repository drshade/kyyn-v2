{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.EvolutionExecution (EvolutionExecution(..), evaluateEvolution) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Evolution (CapturedEvolution, PreviewRejection, EvaluatedEvolution)

data EvolutionExecution :: Effect where
  EvaluateEvolution :: CapturedEvolution -> EvolutionExecution m (Either PreviewRejection EvaluatedEvolution)

type instance DispatchOf EvolutionExecution = Dynamic

evaluateEvolution :: EvolutionExecution :> es => CapturedEvolution -> Eff es (Either PreviewRejection EvaluatedEvolution)
evaluateEvolution = send . EvaluateEvolution
