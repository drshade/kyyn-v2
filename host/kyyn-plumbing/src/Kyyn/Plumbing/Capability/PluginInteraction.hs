{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.PluginInteraction
  ( Waiting(..), waitSeconds, LoginInteraction(..), displayInstructions ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)

data Waiting :: Effect where
  WaitSeconds :: Int -> Waiting m ()
type instance DispatchOf Waiting = Dynamic

waitSeconds :: Waiting :> es => Int -> Eff es ()
waitSeconds = send . WaitSeconds

data LoginInteraction :: Effect where
  DisplayInstructions :: String -> LoginInteraction m ()
type instance DispatchOf LoginInteraction = Dynamic

displayInstructions :: LoginInteraction :> es => String -> Eff es ()
displayInstructions = send . DisplayInstructions
