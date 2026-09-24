{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Plumbing.Capability.Judgement (Judgement(..), judge) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Types.Judgement (JudgementRequest, JudgementFailure, JudgementAnswer)

data Judgement :: Effect where
  Judge :: JudgementRequest -> Judgement m (Either JudgementFailure [JudgementAnswer])
type instance DispatchOf Judgement = Dynamic

judge :: Judgement :> es => JudgementRequest -> Eff es (Either JudgementFailure [JudgementAnswer])
judge = send . Judge
