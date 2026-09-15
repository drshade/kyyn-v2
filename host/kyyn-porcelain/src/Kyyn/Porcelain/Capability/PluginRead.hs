{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.PluginRead
  ( PluginRead(..), loadCapturedInput, executeCapturedMethod, callCapturedMethod ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Data.Aeson (Value)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence (ConnectorInstanceRef, EvidenceProducer, CurrentEvidence)
import Kyyn.Types.Plugin (FetchError(..))
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedMethod)

data PluginRead :: Effect where
  LoadCapturedInput :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
    -> PluginRead m (Either [Diagnostic] CurrentEvidence)
  ExecuteCapturedMethod :: CurrentEvidence -> PreparedMethod -> Value
    -> PluginRead m (Either [Diagnostic] (Either FetchError CheckedValue))
type instance DispatchOf PluginRead = Dynamic

callCapturedMethod :: PluginRead :> es
  => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> PreparedMethod -> Value
  -> Eff es (Either [Diagnostic] CheckedValue)
callCapturedMethod instanceRef producer payload method value = runExceptT $ do
  current <- ExceptT (loadCapturedInput instanceRef producer payload)
  output <- ExceptT (executeCapturedMethod current method value)
  either (\(FetchError message) -> throwE [errorDiagnostic "plugin.read-failed" message]) pure output

loadCapturedInput :: PluginRead :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Eff es (Either [Diagnostic] CurrentEvidence)
loadCapturedInput instanceRef producer = send . LoadCapturedInput instanceRef producer

executeCapturedMethod :: PluginRead :> es => CurrentEvidence -> PreparedMethod -> Value
  -> Eff es (Either [Diagnostic] (Either FetchError CheckedValue))
executeCapturedMethod current method = send . ExecuteCapturedMethod current method
