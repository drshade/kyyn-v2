{-# LANGUAGE GADTs, LambdaCase, OverloadedRecordDot, ScopedTypeVariables, TypeApplications #-}
module Kyyn.Porcelain.Interpreter.FlowWorker (runFlowWorker) where

import Control.Monad (void, forM_)
import Data.Aeson (toJSON)
import Data.List (find)
import Data.Maybe (isNothing)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (catchError)
import Kyyn.Domain.FlowInstance
import Kyyn.Domain.FlowClosure (FlowDeclaration(..))
import Kyyn.Domain.CompiledProgram (CompiledProgram(..))
import Kyyn.Domain.Contract (contractShape)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase, knowledgeBaseScope)
import Kyyn.Domain.Path (scopePath, directoryScope, relativePath)
import qualified Kyyn.Domain.RecipeRun as Run
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.DocumentPersistence
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import Kyyn.Plumbing.Capability.Judgement (Judgement)
import Kyyn.Plumbing.Capability.ModelTurn (ModelTurn)
import Kyyn.Plumbing.Protocol.Interactive (parseProgress, parseFulfilment)
import Kyyn.Plumbing.Protocol.Tool (encodeFlowValue)
import Kyyn.Porcelain.Capability.FlowWorker
import Kyyn.Porcelain.Capability.FlowStore
import Kyyn.Porcelain.Capability.FlowPreparation
import Kyyn.Porcelain.Capability.FlowJournal
import Kyyn.Porcelain.Capability.RecipeRunStore
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore)
import Kyyn.Porcelain.Capability.PluginRead (PluginRead)
import Kyyn.Porcelain.Interpreter.FlowJournal (runFlowJournalLocked)
import Kyyn.Porcelain.Protocol.ToolBroker (executeInteractiveProgram, ProgramFailure(..), programDiagnostics)
import qualified Kyyn.Types.Guest as G
import System.FilePath ((</>))

-- One visit advances at most one instance. A foreground loop owns polling;
-- ingress and cancellation remain independent short catalog transactions.
runFlowWorker :: forall es a. (DocumentPersistence :> es, FlowStore :> es,
  RecipeRunStore :> es, EvidenceStore :> es, PluginRead :> es, GuestExecution :> es,
  Failure :> es, Judgement :> es, ModelTurn :> es, DhallHandling :> es)
  => KnowledgeBase -> Eff (FlowWorker : es) a -> Eff es a
runFlowWorker kb = interpret $ \_ -> \case
  WriterIsBusy identity -> readInstance identity >>= \case
    Nothing -> pure False
    Just _ -> isNothing <$> locked identity (pure ())
  VisitInstance identity -> readInstance identity >>= \case
    Nothing -> pure NoWork
    Just _ -> visit identity
  where
    visit identity = do
      result <- locked identity $ readInstance identity >>= \case
        Nothing -> pure NoWork
        Just current | finished current -> pure NoWork
        Just current | current.retryRequired -> pure Blocked
        Just current | not (eligible current) -> pure NoWork
        Just current -> case current.launch.owner of
          External -> pure NoWork
          Hosted bundleId selected -> readExecutionBundle bundleId >>= \case
            Left problems -> block identity problems
            Right bundle -> case find ((== selected) . (.declaration.recipe)) bundle.closure of
              Nothing -> block identity [errorDiagnostic "flow.entry" "Captured recipe is missing from the execution bundle"]
              Just entry -> do
                let journal = FlowJournalIdentity (flowInstanceIdText identity) current.launch.revision current.launch.request
                -- Cancellation may have arrived while reading the pinned executable.
                readInstance identity >>= \case
                  Just latest | finished latest -> pure NoWork
                  Just latest | latest.retryRequired -> pure Blocked
                  Just latest | eligible latest -> do
                    _ <- blockInstance identity []
                    outcome <- catchError @Failure.OperationalFailure
                      (runFlowJournalLocked journal (work journal bundle entry latest))
                      (\_ problem -> do
                        _ <- blockAttempt identity [Failure.operationalDiagnostic problem]
                        raiseFailure problem)
                    case outcome of
                      Left problem -> stop identity [journalDiagnostic problem]
                      Right outcomeVisit -> pure outcomeVisit
                  _ -> pure NoWork
      pure (maybe WriterBusy id result)
    eligible item = case item.status of
      Finished{} -> False
      Waiting -> any (isNothing . (.outcome)) item.deliveries
      _ -> True
    block identity problems = blockInstance identity problems >>= blockedResult
    stop identity problems = blockAttempt identity problems >>= blockedResult
    blockedResult (Left AlreadyFinished) = pure NoWork
    blockedResult _ = pure Blocked
    journalDiagnostic JournalIdentityMismatch = errorDiagnostic "flow.journal-identity"
      "The saved journal belongs to a different execution revision or original input."
    journalDiagnostic JournalCompletionConflict = errorDiagnostic "flow.journal-conflict"
      "A completed journal operation was presented with a different result. The saved result was preserved."
    journalDiagnostic (JournalCorrupt message) = errorDiagnostic "flow.journal-corrupt"
      ("The saved journal cannot be read: " ++ Text.unpack message)
    locked :: FlowInstanceId -> Eff (DocumentAccess : es) b -> Eff es (Maybe b)
    locked identity action = do
      base <- checked (knowledgeBaseScope kb)
      directory <- checked (directoryScope (scopePath base </> ".kyyn/flows/journals" </> Text.unpack (flowInstanceIdText identity)))
      file <- checked (relativePath "journal.json")
      tryLockedDocument directory file action
    checked = either (raiseFailure . Failure.StorageUnavailable . Failure.StorageDiagnostic Failure.InspectEntry ".kyyn/flows") pure
    work journal bundle entry initial = do
      -- Actual guest codecs validate queued values; accepted/duplicate provenance
      -- is resolved by the catalog, including a cancellation racing with fulfil.
      forM_ [item | item <- initial.deliveries, isNothing item.outcome] $ \delivery ->
        readInstance initial.instanceId >>= \case
          Just current | not (finished current) && null current.blocked -> case find ((== delivery.waitId) . (.waitId)) current.waits of
            Just pending | pending.waitStatus /= Closed -> do
              answer <- invoke journal bundle entry (const (pure ()))
                (G.FulfilFlow journal.namespace journal.revision pending.descriptor (encodeFlowValue delivery.value))
              case either (Left . programDiagnostics) Right answer >>= protocol . parseFulfilment of
                Left problems -> void (blockAttempt initial.instanceId problems)
                Right resolution -> void (resolveDelivery initial.instanceId delivery.deliveryId resolution)
            _ -> void (resolveDelivery initial.instanceId delivery.deliveryId ClosedWait)
          _ -> pure ()
      readInstance initial.instanceId >>= \case
        Just current | not (null current.blocked) -> pure Blocked
        Just current | current.status == Runnable || current.status == Running ->
          beginAttempt current.instanceId >>= \case
            Left _ -> pure NoWork
            Right _ -> record journal bundle entry current
        _ -> pure NoWork
    finished item = case item.status of Finished{} -> True; _ -> False
    invoke journal bundle entry observe invocation = executeInteractiveProgram journal observe entry.entry bundle.plugins bundle.model (toJSON invocation)
    protocol = either (Left . pure . errorDiagnostic "flow.protocol") Right
    record journal bundle entry current = withRecipeRun
      (Run.PreparedRecipeRun kb entry.declaration.recipe entry.declaration.entry bundle.revision
        bundle.program.identity entry.graph entry.mermaid (Just current.instanceId)) $ \writer@(RecipeRunWriter _ header) -> do
      linked <- linkAttempt current.instanceId header.runId
      case linked of
        Left _ -> appendRunEvent writer Run.RunCancelled >> pure NoWork
        Right _ -> execute writer journal bundle entry current
    execute writer journal bundle entry current = do
      result <- invoke journal bundle entry (void . appendRunEvent writer . Run.FlowObserved)
        (G.ResumeFlow journal.namespace journal.revision journal.input)
      case result of
        Left failure@GuestFailure{} -> do
          let problems = programDiagnostics failure
          -- A returned FetchError is authoritative. Transport/recording failures
          -- are not; they leave the previous frontier for a later replay.
          publish writer current (Run.RunFailed problems) (finishInstance current.instanceId (Failed problems))
        Left (InvocationFailure problems) -> interrupted writer current problems
        Right value -> case protocol (parseProgress journal.namespace journal.revision value) of
          Left problems -> interrupted writer current problems
          Right (FlowWaiting frontier) -> publish writer current
            (Run.RunSuspended (fromIntegral (length frontier))) (reportFrontier current.instanceId frontier)
          Right (FlowReturned output) -> encodeValue (contractShape entry.outputContract) output >>= \case
            Left problems -> interrupted writer current problems
            Right _ -> publish writer current Run.RunReturned (finishInstance current.instanceId (Completed output))
    interrupted writer current problems = do
      _ <- appendRunEvent writer (Run.RunFailed problems)
      stop current.instanceId problems
    -- Recording failure must stop dispatch before changing the durable frontier.
    -- Cancellation may race with publication; a terminal catalog state wins.
    publish writer current terminal update = do
      readInstance current.instanceId >>= \case
        Just latest | not (finished latest) -> do
          _ <- appendRunEvent writer terminal
          update >>= \case
            Right _ -> pure Advanced
            Left AlreadyFinished -> pure NoWork
            Left MissingInstance -> pure NoWork
            Left problem -> stop current.instanceId [errorDiagnostic "flow.transition" (show problem)]
        _ -> appendRunEvent writer Run.RunCancelled >> pure NoWork
