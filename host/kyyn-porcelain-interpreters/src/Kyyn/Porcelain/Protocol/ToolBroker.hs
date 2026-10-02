{-# LANGUAGE GADTs, TypeApplications, LambdaCase #-}
module Kyyn.Porcelain.Protocol.ToolBroker (executeToolProgram) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (Value, encode)
import qualified Data.ByteString.Lazy as Lazy
import Data.Coerce (coerce)
import Effectful (Eff, (:>))
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Effectful.State.Static.Local (evalState, get, modify)
import Kyyn.Domain.Contract (contractId)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..), CurrentEvidence(..), EvidenceSnapshotRef(..), EvidenceProducer(..))
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
import Kyyn.Plumbing.Protocol.PluginMessages (success, failure)
import Kyyn.Plumbing.Protocol.Tool (ToolCall(..), decodeToolFrame)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.PluginRead (PluginRead, loadCapturedInput, executeCapturedMethod)
import Kyyn.Porcelain.Protocol.PluginBroker (conversation, protocolFailure)

executeToolProgram :: (PluginRead :> es, GuestExecution :> es, Failure :> es, Judgement.Judgement :> es, Model.ModelTurn :> es)
  => CompiledProgram -> [PreparedPlugin] -> Maybe ModelConfiguration -> [CurrentEvidence]
  -> Value -> Eff es (Either [Diagnostic] Value)
executeToolProgram program plugins model captured arguments = runExceptT $ do
  result <- ExceptT $ runErrorNoCallStack @[Diagnostic] $ evalState [(instanceRef,current) | current@(CurrentEvidence (EvidenceSnapshotRef instanceRef _ _) _) <- captured] $
    conversation decodeToolFrame program (Lazy.toStrict (encode arguments)) $ \case
      ToolJudgement request -> Judgement.judge request >>= either protocolFailure pure . Judgement.encodeReply
      ToolModel request -> case model of
        Nothing -> pure (failure "No model configured; add root/model.dhall through an evolution")
        Just configuration -> Model.takeModelTurn configuration request >>= either protocolFailure pure . Model.encodeReply
      ToolCall plugin kind instanceName methodName value -> answerPlugin plugins plugin kind instanceName methodName value
  value <- either (\(FetchError message) -> throwE [errorDiagnostic "tool.failed" message]) pure result
  pure value
  where
    answerPlugin configured plugin kind instanceName methodName value = do
      let label = pluginNameText plugin ++ "/" ++ coerce instanceName
      (PreparedPackage _ identity _, ConfiguredConnector _ _ (PreparedConnector {connectorType = actual, payloadContract = payload, methods = methods}) _) <-
        either (protocolFailure . ((label ++ ": ") ++) . show) pure (selectedInstance plugin instanceName configured)
      if actual /= kind then protocolFailure (label ++ ": connector type differs from the requested method") else pure ()
      method <- case [m | m@(PreparedMethod n _ _ _ _) <- methods, n == methodName] of
        [m] -> pure m
        _ -> protocolFailure (label ++ ": no captured method named " ++ coerce methodName)
      let instanceRef = ConnectorInstanceRef plugin (coerce instanceName)
      loaded <- lookup instanceRef <$> get @[(ConnectorInstanceRef,CurrentEvidence)]
      current <- case loaded of
        Just current -> pure current
        Nothing -> do
          current <- loadCapturedInput instanceRef (EvidenceProducer identity (contractId payload)) payload >>= either throwError pure
          modify ((instanceRef,current):)
          pure current
      reply <- executeCapturedMethod current method value >>= either throwError pure
      pure (either (\(FetchError message) -> failure message) (\(CheckedValue _ resultValue) -> success resultValue) reply)
