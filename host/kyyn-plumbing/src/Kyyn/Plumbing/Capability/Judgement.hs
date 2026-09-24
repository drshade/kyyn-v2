{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Plumbing.Capability.Judgement (Judgement(..), judge) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Types.Judgement (JudgementRequest, JudgementFailure, Judged)

data Judgement :: Effect where
  Judge :: JudgementRequest a -> Judgement m (Either JudgementFailure (Judged a))
type instance DispatchOf Judgement = Dynamic

judge :: Judgement :> es => JudgementRequest a -> Eff es (Either JudgementFailure (Judged a))
judge = send . Judge
