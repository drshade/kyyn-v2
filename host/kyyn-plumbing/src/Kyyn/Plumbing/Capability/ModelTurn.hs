{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Plumbing.Capability.ModelTurn (ModelTurn(..), takeModelTurn) where

import Agentic.Runtime (Conversation, Turn)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Model (ModelConfiguration, ModelFailure)

data ModelTurn :: Effect where
  TakeModelTurn :: ModelConfiguration -> Conversation -> ModelTurn m (Either ModelFailure Turn)
type instance DispatchOf ModelTurn = Dynamic

takeModelTurn :: ModelTurn :> es => ModelConfiguration -> Conversation -> Eff es (Either ModelFailure Turn)
takeModelTurn configuration = send . TakeModelTurn configuration
