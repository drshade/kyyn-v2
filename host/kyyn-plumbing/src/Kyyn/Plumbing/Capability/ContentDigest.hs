{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.ContentDigest (ContentDigest(..), digestText) where
import Data.Text (Text)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)

data ContentDigest :: Effect where
  DigestText :: [Text] -> ContentDigest m [Text]
type instance DispatchOf ContentDigest = Dynamic

digestText :: ContentDigest :> es => [Text] -> Eff es [Text]
digestText = send . DigestText
