{-# LANGUAGE GADTs, TypeApplications, LambdaCase #-}
module Kyyn.Porcelain.Protocol.ToolBroker (executeToolProgram, executeToolProgramCaptured) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (Value, encode)
import qualified Data.ByteString.Lazy as Lazy
import Data.Coerce (coerce)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Effectful.State.Static.Local (runState, get, modify)
import Kyyn.Domain.Contract (contractId)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..), EvidenceSnapshotRef(..))
import Kyyn.Domain.EvidenceIndex (EvidenceIndex(EvidenceIndex), EvidenceSelection(EvidenceSelection))
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore)
import Kyyn.Domain.Plugin (pluginNameText, ConnectorName(..), MethodName(..))
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Model (ModelConfiguration)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Plugin (FetchError(..))
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.Failure (Failure)
import qualified Kyyn.Plumbing.Capability.Judgement as Judgement
import qualified Kyyn.Plumbing.Protocol.Judgement as Judgement
import qualified Kyyn.Plumbing.Capability.ModelTurn as Model
import qualified Kyyn.Plumbing.Protocol.ModelTurn as Model
import Kyyn.Plumbing.Protocol.PluginMessages (PluginCall(..), success, failure)
import Kyyn.Plumbing.Protocol.Tool (ToolCall(..), decodeToolFrame)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.PluginRead (PluginRead, loadCapturedInput, executeCapturedMethod)
import Kyyn.Porcelain.Protocol.PluginBroker (conversation, protocolFailure, answerEvidence)

executeToolProgram :: (EvidenceStore :> es, PluginRead :> es, GuestExecution :> es, Failure :> es, Judgement.Judgement :> es, Model.ModelTurn :> es)
  => CompiledProgram -> [PreparedPlugin] -> Maybe ModelConfiguration -> [EvidenceIndex]
  -> Value -> Eff es (Either [Diagnostic] Value)
executeToolProgram program plugins model captured arguments = fmap (fmap fst)
  (executeToolProgramCaptured program plugins model captured arguments)

executeToolProgramCaptured :: (EvidenceStore :> es, PluginRead :> es, GuestExecution :> es, Failure :> es, Judgement.Judgement :> es, Model.ModelTurn :> es)
  => CompiledProgram -> [PreparedPlugin] -> Maybe ModelConfiguration -> [EvidenceIndex]
  -> Value -> Eff es (Either [Diagnostic] (Value, [EvidenceIndex]))
executeToolProgramCaptured program plugins model captured arguments = runExceptT $ do
  (result,contexts) <- ExceptT $ runErrorNoCallStack @[Diagnostic] $ runState @[(ConnectorInstanceRef,EvidenceIndex)] [] $
    conversation decodeToolFrame program (Lazy.toStrict (encode arguments)) $ \case
      ToolJudgement request -> Judgement.judge request >>= either protocolFailure pure . Judgement.encodeReply
      ToolModel request -> case model of
        Nothing -> pure (failure "No model configured; add root/model.dhall through an evolution")
        Just configuration -> Model.takeModelTurn configuration request >>= either protocolFailure pure . Model.encodeReply
      ToolCall plugin kind instanceName methodName value -> answerPlugin plugins plugin kind instanceName methodName value
      ToolEvidenceList plugin kind instanceName -> do
        (identity,payload,_) <- connector plugins plugin kind instanceName
        current <- capture plugin kind instanceName identity payload
        answerEvidence (Just current) (ListEvidence "selected")
      ToolEvidenceRead plugin kind instanceName key -> do
        (identity,payload,_) <- connector plugins plugin kind instanceName
        current <- capture plugin kind instanceName identity payload
        answerEvidence (Just current) (ReadEvidence "selected" key)
  value <- either (\(FetchError message) -> throwE [errorDiagnostic "tool.failed" (Text.unpack message)]) pure result
  pure (value,map snd contexts)
  where
    answerPlugin configured plugin kind instanceName methodName value = do
      (identity,payload,methods) <- connector configured plugin kind instanceName
      method <- case [m | m@(PreparedMethod n _ _ _ _) <- methods, n == methodName] of
        [m] -> pure m
        _ -> protocolFailure (pluginNameText plugin ++ "/" ++ coerce instanceName ++ ": no captured method named " ++ coerce methodName)
      current <- capture plugin kind instanceName identity payload
      reply <- executeCapturedMethod current method value >>= either throwError pure
      pure (either (\(FetchError message) -> failure (Text.unpack message)) (\(CheckedValue _ resultValue) -> success resultValue) reply)
    connector configured plugin kind instanceName = do
      let label = pluginNameText plugin ++ "/" ++ coerce instanceName
      (PreparedPackage _ identity _, ConfiguredConnector _ _ selected _) <-
        either (protocolFailure . ((label ++ ": ") ++) . show) pure (selectedInstance plugin instanceName configured)
      (actual,payload,_,methods,_,_,_) <- either (protocolFailure . show) pure (sourceDetails selected)
      if actual /= kind then protocolFailure (label ++ ": connector type differs from the requested method") else pure ()
      pure (identity,payload,methods)
    capture plugin kind instanceName identity payload = do
      let instanceRef = ConnectorInstanceRef plugin (coerce instanceName)
      loaded <- lookup instanceRef <$> get @[(ConnectorInstanceRef,EvidenceIndex)]
      case loaded of
        Just current -> pure current
        Nothing -> do
          current <- case [c | c@(EvidenceIndex (EvidenceSnapshotRef selected _ _) _ _ _) <- captured, selected == instanceRef] of
            c@(EvidenceIndex _ _ actual _):_ | contractId actual == contractId payload -> pure c
            _: _ -> protocolFailure "Captured payload contract differs from the prepared connector"
            [] -> loadCapturedInput (EvidenceSelection instanceRef kind identity) payload >>= either throwError pure
          modify ((instanceRef,current):)
          pure current
