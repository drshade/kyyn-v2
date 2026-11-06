{-# LANGUAGE DeriveAnyClass, DerivingStrategies, DeriveGeneric, OverloadedStrings #-}
module Fixture.Plugin (connectors, count, fetch, validate) where

import GHC.Generics (Generic)
import Kyyn.Contract (Contract)
import Kyyn.Plugin
import Kyyn.Plugin.Host (Acquisition)
import Kyyn.Types.Diagnostic (ValidationReport(..))

-- Deliberately private: adapters infer the actual type without inventing imports.
data Payload = Payload { number :: Integer }
  deriving stock Generic
  deriving anyclass Contract

connectors :: [Connector]
connectors = [SourceConnector "Files" "Fixture.Plugin.fetch" "Fixture.Plugin.validate"
  [CapturedMethod "count" "Count captured files" "Fixture.Plugin.count"] Nothing]

count :: () -> EvidenceSnapshot Payload -> CapturedRead Payload (Either FetchError Integer)
count () snapshot = fmap (fmap (toInteger . length)) (listEvidenceIds snapshot)

fetch :: () -> EvidenceSnapshot Payload -> Acquisition Payload (Either FetchError [EvidenceChange Payload])
fetch () _ = pure (Right [])

validate :: () -> ValidationReport
validate () = ValidationReport []
