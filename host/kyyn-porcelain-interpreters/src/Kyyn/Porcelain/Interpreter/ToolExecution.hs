{-# LANGUAGE GADTs, TypeApplications, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.ToolExecution (runToolExecution) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as Lazy
import Data.Coerce (coerce)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Effectful.State.Static.Local (evalState, get, modify)
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..), CurrentEvidence, EvidenceProducer(..))
import Kyyn.Domain.Plugin (pluginNameText, ConnectorName(..), MethodName(..))
import Kyyn.Domain.Tool (ToolDescriptor(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Plugin (FetchError(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.Failure (Failure)
import qualified Kyyn.Plumbing.Capability.Judgement as Judgement
import qualified Kyyn.Plumbing.Protocol.Judgement as Judgement
import Kyyn.Plumbing.Protocol.PluginMessages (success, failure)
import Kyyn.Plumbing.Protocol.Tool (ToolCall(..), decodeToolFrame)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.PluginRead (PluginRead, loadCapturedInput, executeCapturedMethod)
import Kyyn.Porcelain.Capability.Tool
import Kyyn.Porcelain.Protocol.PluginBroker (conversation, protocolFailure)

runToolExecution :: (PluginRead :> es, GuestExecution :> es, DhallHandling :> es, Failure :> es, Judgement.Judgement :> es)
  => Eff (ToolExecution : es) a -> Eff es a
runToolExecution = interpret $ \_ (ExecuteTool (PreparedTool (ToolDescriptor _ _ input output) program plugins) arguments) -> runExceptT $ do
  _ <- ExceptT (encodeValue (contractShape input) arguments)
  result <- ExceptT $ runErrorNoCallStack @[Diagnostic] $ evalState ([] :: [(ConnectorInstanceRef,CurrentEvidence)]) $
    conversation decodeToolFrame program (Lazy.toStrict (encode arguments)) $ \case
      ToolJudgement request -> Judgement.encodeReply <$> Judgement.judge request
      ToolCall plugin kind instanceName methodName value -> answerPlugin plugins plugin kind instanceName methodName value
  value <- either (\(FetchError message) -> throwE [errorDiagnostic "tool.failed" message]) pure result
  _ <- ExceptT (encodeValue (contractShape output) value)
  pure (CheckedValue (contractId output) value)
  where
    answerPlugin configured plugin kind instanceName methodName value = do
      let label = pluginNameText plugin ++ "/" ++ coerce instanceName
      (PreparedPackage _ identity _, ConfiguredConnector _ _ (PreparedConnector actual _ payload _ _ methods) _) <-
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
