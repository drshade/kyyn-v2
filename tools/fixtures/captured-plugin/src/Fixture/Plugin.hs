{-# LANGUAGE DeriveAnyClass, DerivingStrategies, DeriveGeneric, OverloadedStrings #-}
module Fixture.Plugin (connectors, count, fetch, fetchOptions, fetchState, fetchStateOptions, validate) where

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
  [CapturedMethod "count" "Count captured files" "Fixture.Plugin.count"] Nothing,
  SourceConnector "Options" "Fixture.Plugin.fetchOptions" "Fixture.Plugin.validate" [] Nothing,
  SourceConnector "State" "Fixture.Plugin.fetchState" "Fixture.Plugin.validate" [] Nothing,
  SourceConnector "StateOptions" "Fixture.Plugin.fetchStateOptions" "Fixture.Plugin.validate" [] Nothing]

count :: () -> EvidenceSnapshot Payload -> CapturedRead Payload (Either FetchError Integer)
count () snapshot = fmap (fmap (toInteger . length)) (listEvidenceIds snapshot)

fetch :: Integer -> EvidenceSnapshot Payload -> Acquisition Payload (Either FetchError [EvidenceChange Payload])
fetch _ _ = pure (Right [])

validate :: Integer -> ValidationReport
validate _ = ValidationReport []

fetchOptions :: Integer -> Maybe Integer -> EvidenceSnapshot Payload -> Acquisition Payload (Either FetchError [EvidenceChange Payload])
fetchOptions _ _ _ = pure (Right [])

fetchState :: Integer -> FetchContext Integer -> EvidenceSnapshot Payload
  -> Acquisition Payload (Either FetchError (FetchResult Payload Integer Integer))
fetchState config (FetchContext _ prior) _ = pure (Right (FetchResult [] (config + maybe 0 id prior) 5))

fetchStateOptions :: Integer -> Maybe Integer -> FetchContext Integer -> EvidenceSnapshot Payload
  -> Acquisition Payload (Either FetchError (FetchResult Payload Integer Integer))
fetchStateOptions config options = fetchState (config + maybe 0 id options)
