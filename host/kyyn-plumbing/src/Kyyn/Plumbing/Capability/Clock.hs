{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.Clock (Clock(..), currentTime) where
import Data.Time (UTCTime)
import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
data Clock :: Effect where
  CurrentTime :: Clock m UTCTime
type instance DispatchOf Clock = Dynamic
currentTime :: Clock :> es => Eff es UTCTime
currentTime = send CurrentTime
