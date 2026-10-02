{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Plumbing.Capability.Judgement (Judgement(..), judge) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Agentic.Questions (JudgeRequest, Answer)
import Kyyn.Domain.Model (ModelFailure)

data Judgement :: Effect where
  Judge :: JudgeRequest -> Judgement m (Either ModelFailure [Answer])
type instance DispatchOf Judgement = Dynamic

judge :: Judgement :> es => JudgeRequest -> Eff es (Either ModelFailure [Answer])
judge = send . Judge
