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
import Kyyn.Domain.EvidenceIndex (EvidenceSelection, EvidenceIndex)
import Kyyn.Types.Plugin (FetchError(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedMethod(..))

data PluginRead :: Effect where
  LoadCapturedInput :: EvidenceSelection -> CheckedContract
    -> PluginRead m (Either [Diagnostic] EvidenceIndex)
  ExecuteCapturedMethod :: EvidenceIndex -> PreparedMethod -> Value
    -> PluginRead m (Either [Diagnostic] (Either FetchError CheckedValue))
  ResolveCapturedBlobs :: [EvidenceIndex] -> CheckedContract -> Value
    -> PluginRead m (Either [Diagnostic] [ResolvedBlob])
type instance DispatchOf PluginRead = Dynamic

callCapturedMethod :: PluginRead :> es
  => EvidenceSelection -> CheckedContract -> PreparedMethod -> Value
  -> Eff es (Either [Diagnostic] (CheckedValue, [ResolvedBlob]))
callCapturedMethod selection payload method@(PreparedMethod _ _ _ result _) value = runExceptT $ do
  current <- ExceptT (loadCapturedInput selection payload)
  output <- ExceptT (executeCapturedMethod current method value)
  checked@(CheckedValue _ resultValue) <- either (\(FetchError message) -> throwE [errorDiagnostic "plugin.read-failed" (Text.unpack message)]) pure output
  paths <- ExceptT (resolveCapturedBlobs [current] result resultValue)
  pure (checked,paths)

resolveCapturedBlobs :: PluginRead :> es => [EvidenceIndex] -> CheckedContract -> Value
  -> Eff es (Either [Diagnostic] [ResolvedBlob])
resolveCapturedBlobs contexts contract = send . ResolveCapturedBlobs contexts contract

loadCapturedInput :: PluginRead :> es => EvidenceSelection -> CheckedContract -> Eff es (Either [Diagnostic] EvidenceIndex)
loadCapturedInput selection = send . LoadCapturedInput selection

executeCapturedMethod :: PluginRead :> es => EvidenceIndex -> PreparedMethod -> Value
  -> Eff es (Either [Diagnostic] (Either FetchError CheckedValue))
executeCapturedMethod current method = send . ExecuteCapturedMethod current method
