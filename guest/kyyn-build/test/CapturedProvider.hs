{-# LANGUAGE DeriveAnyClass, DerivingStrategies #-}
-- Deliberately export neither the result type nor the input alias: generated
-- bindings must retain compiler identities, not invent source imports for them.
module CapturedProvider (content, fetch, bad) where

import Data.Text (Text)
import GHC.Generics (Generic)
import Kyyn.Contract (Contract)
import Kyyn.Plugin (CapturedRead, EvidenceSnapshot, FetchError(..), EvidenceChange)
import Kyyn.Plugin.Host (Acquisition)

type Key = Text
data HiddenPayload = HiddenPayload { count :: Integer }
  deriving stock (Generic) deriving anyclass (Contract)
data HiddenResult = HiddenResult { value :: Text }
  deriving stock (Generic) deriving anyclass (Contract)

content :: Key -> EvidenceSnapshot HiddenPayload -> CapturedRead HiddenPayload (Either FetchError HiddenResult)
content _ _ = pure (Left (FetchError mempty))

bad :: Text -> Text
bad = id

fetch :: () -> EvidenceSnapshot HiddenPayload -> Acquisition HiddenPayload (Either FetchError [EvidenceChange HiddenPayload])
fetch () _ = pure (Right [])
