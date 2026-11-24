{-# LANGUAGE GADTs, TypeApplications, LambdaCase, OverloadedRecordDot #-}
module Kyyn.Porcelain.Protocol.ToolBroker (executeToolProgram, executeToolProgramCaptured, executeRecordedRecipeProgram, executeInteractiveProgram, ProgramFailure(..), programDiagnostics) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (Value, object)
import Control.Monad (void)
import Data.Bifunctor (first)
import Kyyn.Porcelain.Capability.FlowJournal (FlowJournal, FlowJournalIdentity(..), lookupCompletion, saveCompletion)
import Kyyn.Porcelain.Capability.RecipeRunStore (RecipeRunStore, RecipeRunWriter, appendRunEvent)
import Kyyn.Domain.RecipeRun (RunEventBody(FlowObserved), FlowObservation)
import Data.Coerce (coerce)
import qualified Data.Text as Text
import Effectful (Eff, (:>), raise)
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Effectful.State.Static.Local (runState, get, modify)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evidence (ConnectorInstanceRef(..), EvidenceSnapshotRef(..))
import Kyyn.Domain.EvidenceIndex (EvidenceIndex(EvidenceIndex), EvidenceSelection(EvidenceSelection))
import qualified Kyyn.Domain.EvidenceIndex as Index
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore)
import Kyyn.Domain.Plugin (pluginNameText, ConnectorName(..), MethodName(..))
import Kyyn.Domain.CompiledEntry (CompiledEntry)
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
import Kyyn.Plumbing.Protocol.Tool (ToolCall(..), JournalCall(..), FlowControlCall, encodeJournalLookup, decodeToolFrame)
import Kyyn.Porcelain.Capability.PluginLive (PluginLive, executeLiveQuery)
import Kyyn.Domain.Contract (descriptionOf)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.PluginRead (PluginRead, loadCapturedInput, executeCapturedMethod)
import Kyyn.Porcelain.Protocol.PluginBroker (conversation, protocolFailure, answerEvidence)

-- Keep a returned guest Left distinct from failure to execute/observe it.
-- Callers deciding logical lifecycle must not classify diagnostic strings.
data ProgramFailure = GuestFailure FetchError | InvocationFailure [Diagnostic] deriving Show
programDiagnostics :: ProgramFailure -> [Diagnostic]
programDiagnostics (GuestFailure (FetchError message)) = [errorDiagnostic "tool.failed" (Text.unpack message)]
programDiagnostics (InvocationFailure problems) = problems

executeToolProgram :: (EvidenceStore :> es, PluginRead :> es, GuestExecution :> es, Failure :> es, Judgement.Judgement :> es, Model.ModelTurn :> es)
  => CompiledEntry -> [PreparedPlugin] -> Maybe ModelConfiguration -> [EvidenceIndex]
  -> Value -> Eff es (Either [Diagnostic] Value)
executeToolProgram program plugins model captured arguments = fmap (fmap fst)
  (executeToolProgramCaptured program plugins model captured arguments)

executeToolProgramCaptured :: (EvidenceStore :> es, PluginRead :> es, GuestExecution :> es, Failure :> es, Judgement.Judgement :> es, Model.ModelTurn :> es)
  => CompiledEntry -> [PreparedPlugin] -> Maybe ModelConfiguration -> [EvidenceIndex]
  -> Value -> Eff es (Either [Diagnostic] (Value, [EvidenceIndex]))
executeToolProgramCaptured = executeProgram Nothing Nothing Nothing Nothing

executeRecordedRecipeProgram :: (RecipeRunStore :> es, EvidenceStore :> es, PluginRead :> es, GuestExecution :> es, Failure :> es, Judgement.Judgement :> es, Model.ModelTurn :> es)
  => RecipeRunWriter -> CompiledEntry -> [PreparedPlugin] -> Maybe ModelConfiguration
  -> Value -> Eff es (Either [Diagnostic] Value)
executeRecordedRecipeProgram writer program plugins model arguments = fmap (fmap fst)
  (executeProgram (Just (\summary -> void (appendRunEvent writer (FlowObserved summary)))) Nothing Nothing Nothing program plugins model [] arguments)

executeInteractiveProgram :: (PluginLive :> es, FlowJournal :> es, EvidenceStore :> es, PluginRead :> es,
  GuestExecution :> es, Failure :> es, Judgement.Judgement :> es, Model.ModelTurn :> es)
  => FlowJournalIdentity -> (FlowObservation -> Eff es ()) -> (FlowControlCall -> Eff es Value) -> CompiledEntry -> [PreparedPlugin]
  -> Maybe ModelConfiguration -> Value -> Eff es (Either ProgramFailure Value)
executeInteractiveProgram identity observe control program plugins model arguments = fmap (fmap fst)
  (executeProgramResult (Just observe) (Just answerJournal) (Just control) (Just answerQuery) program plugins model [] arguments)
  where
    answerQuery (ToolLiveQuery plugin kind instanceName methodName inputContract outputContract value) = do
      (_,ConfiguredConnector _ _ selected config) <- either (protocolFailure . show) pure (selectedInstance plugin instanceName plugins)
      method <- case selected of
        PreparedLiveConnector {connectorType = actual,queries = methods} | actual == kind ->
          case [m | m@(PreparedMethod name _ _ _ _) <- methods, name == methodName] of
            [m] -> pure m
            _ -> protocolFailure "Unknown live query method"
        _ -> protocolFailure "Live query reference does not select its configured connector type"
      let PreparedMethod _ _ input output _ = method
      if descriptionOf input /= inputContract || descriptionOf output /= outputContract
        then protocolFailure "Live query contracts differ from the captured binding" else pure ()
      response <- executeLiveQuery config method value >>= either (protocolFailure . show) pure
      pure (either (\(FetchError message) -> failure (Text.unpack message)) (\(CheckedValue _ result) -> success result) response)
    answerQuery _ = protocolFailure "Expected a live query request"
    answerJournal (InitialiseJournal namespace revision)
      | namespace == identity.namespace && revision == identity.revision = pure (object [])
      | otherwise = protocolFailure "Guest journal identity differs from the locked instance"
    answerJournal (LookupJournal key) = encodeJournalLookup <$> lookupCompletion key
    answerJournal (SaveJournal key value) = saveCompletion key value >> pure (object [])

executeProgram :: (EvidenceStore :> es, PluginRead :> es, GuestExecution :> es, Failure :> es, Judgement.Judgement :> es, Model.ModelTurn :> es)
  => Maybe (FlowObservation -> Eff es ()) -> Maybe (JournalCall -> Eff es Value) -> Maybe (FlowControlCall -> Eff es Value) -> Maybe (ToolCall -> Eff es Value) -> CompiledEntry -> [PreparedPlugin] -> Maybe ModelConfiguration -> [EvidenceIndex]
  -> Value -> Eff es (Either [Diagnostic] (Value, [EvidenceIndex]))
executeProgram observe journal control query program plugins model captured arguments =
  first programDiagnostics <$> executeProgramResult observe journal control query program plugins model captured arguments

executeProgramResult :: (EvidenceStore :> es, PluginRead :> es, GuestExecution :> es, Failure :> es, Judgement.Judgement :> es, Model.ModelTurn :> es)
  => Maybe (FlowObservation -> Eff es ()) -> Maybe (JournalCall -> Eff es Value) -> Maybe (FlowControlCall -> Eff es Value) -> Maybe (ToolCall -> Eff es Value) -> CompiledEntry -> [PreparedPlugin] -> Maybe ModelConfiguration -> [EvidenceIndex]
  -> Value -> Eff es (Either ProgramFailure (Value, [EvidenceIndex]))
executeProgramResult observe journal control query program plugins model captured arguments = runExceptT $ do
  (result,contexts) <- ExceptT $ fmap (first InvocationFailure) $ runErrorNoCallStack @[Diagnostic] $ runState @[(ConnectorInstanceRef,EvidenceIndex)] [] $
    conversation decodeToolFrame program arguments $ \case
      call@ToolLiveQuery{} -> case query of
        Nothing -> protocolFailure "Live queries are only available during hosted interactive recipe execution"
        Just respond -> raise (raise (respond call))
      ToolFlowControl call -> case control of
        Nothing -> protocolFailure "flow-control is only available during hosted interactive recipe execution"
        Just respond -> raise (raise (respond call))
      ToolJournal call -> case journal of
        Nothing -> protocolFailure "flow-journal is only available during interactive recipe execution"
        Just respond -> raise (raise (respond call))
      ToolFlowObserved summary -> case observe of
        Nothing -> protocolFailure "flow/observe is only available during a recorded recipe invocation"
        Just record -> raise (raise (record summary)) >> pure (object [])
      ToolJudgement request -> Judgement.judge request >>= either protocolFailure pure . Judgement.encodeReply
      ToolModel request -> case model of
        Nothing -> pure (failure "No model configured; set the model field to Some configuration in root/kb.dhall through an evolution")
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
  value <- either (throwE . GuestFailure) pure result
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
      (actual,payload,_,methods,_,_,_,_) <- either (protocolFailure . show) pure (sourceDetails selected)
      if actual /= kind then protocolFailure (label ++ ": connector type differs from the requested method") else pure ()
      pure (identity,payload,methods)
    capture plugin kind instanceName identity payload = do
      let instanceRef = ConnectorInstanceRef plugin (coerce instanceName)
      loaded <- lookup instanceRef <$> get @[(ConnectorInstanceRef,EvidenceIndex)]
      case loaded of
        Just current -> pure current
        Nothing -> do
          current <- case [c | c@(EvidenceIndex (EvidenceSnapshotRef selected _ _) _ _ _ _) <- captured, selected == instanceRef] of
            c:_ -> pure c { Index.payloadContract = payload }
            [] -> loadCapturedInput (EvidenceSelection instanceRef kind identity) payload >>= either throwError pure
          modify ((instanceRef,current):)
          pure current
