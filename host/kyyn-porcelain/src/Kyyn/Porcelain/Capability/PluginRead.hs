{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.PluginRead
  ( PluginRead(..), loadCapturedInput, executeCapturedMethod, callCapturedMethod, resolveCapturedBlobs ) where

import qualified Data.Text as Text
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Data.Aeson (Value)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Kyyn.Domain.Contract (CheckedContract)
import Kyyn.Domain.Blob (ResolvedBlob)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence (ConnectorInstanceRef, EvidenceProducer, CurrentEvidence)
import Kyyn.Types.Plugin (FetchError(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedMethod(..))

data PluginRead :: Effect where
  LoadCapturedInput :: ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
    -> PluginRead m (Either [Diagnostic] CurrentEvidence)
  ExecuteCapturedMethod :: CheckedContract -> CurrentEvidence -> PreparedMethod -> Value
    -> PluginRead m (Either [Diagnostic] (Either FetchError CheckedValue))
  ResolveCapturedBlobs :: [(CheckedContract, CurrentEvidence)] -> CheckedContract -> Value
    -> PluginRead m (Either [Diagnostic] [ResolvedBlob])
type instance DispatchOf PluginRead = Dynamic

callCapturedMethod :: PluginRead :> es
  => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract -> PreparedMethod -> Value
  -> Eff es (Either [Diagnostic] (CheckedValue, [ResolvedBlob]))
callCapturedMethod instanceRef producer payload method@(PreparedMethod _ _ _ result _) value = runExceptT $ do
  current <- ExceptT (loadCapturedInput instanceRef producer payload)
  output <- ExceptT (executeCapturedMethod payload current method value)
  checked@(CheckedValue _ resultValue) <- either (\(FetchError message) -> throwE [errorDiagnostic "plugin.read-failed" (Text.unpack message)]) pure output
  paths <- ExceptT (resolveCapturedBlobs [(payload,current)] result resultValue)
  pure (checked,paths)

resolveCapturedBlobs :: PluginRead :> es => [(CheckedContract, CurrentEvidence)] -> CheckedContract -> Value
  -> Eff es (Either [Diagnostic] [ResolvedBlob])
resolveCapturedBlobs contexts contract = send . ResolveCapturedBlobs contexts contract

loadCapturedInput :: PluginRead :> es => ConnectorInstanceRef -> EvidenceProducer -> CheckedContract
  -> Eff es (Either [Diagnostic] CurrentEvidence)
loadCapturedInput instanceRef producer = send . LoadCapturedInput instanceRef producer

executeCapturedMethod :: PluginRead :> es => CheckedContract -> CurrentEvidence -> PreparedMethod -> Value
  -> Eff es (Either [Diagnostic] (Either FetchError CheckedValue))
executeCapturedMethod payload current method = send . ExecuteCapturedMethod payload current method
