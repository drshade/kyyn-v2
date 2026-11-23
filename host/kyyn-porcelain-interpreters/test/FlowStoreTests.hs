-- Native catalog lifecycle: restart, parent/child independence, subtree races,
-- immutable start/reply identities, authoritative frontiers and ingress while a
-- guest journal lock is held. No guest build or provider service is involved.
{-# LANGUAGE DataKinds, OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where

import Control.Concurrent.Async (concurrently, withAsync)
import Control.Concurrent.MVar
import Control.Monad (unless, replicateM_)
import Data.Aeson (Value(..), object)
import qualified Data.Text as Text
import Effectful (Eff, IOE, runEff, liftIO)
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.FlowInstance
import Kyyn.Domain.Git (Repository(..), TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (DirectoryScope, directoryScope)
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Capability.FlowStore
import Kyyn.Porcelain.Capability.FlowJournal (FlowJournalIdentity(FlowJournalIdentity))
import Kyyn.Porcelain.Interpreter.FlowStore (runFlowStore)
import Kyyn.Porcelain.Interpreter.FlowJournal (runFlowJournal)

type Host = '[DocumentPersistence,FileSystem,Failure,IOE]
execute :: DirectoryScope -> Eff Host a -> IO a
execute scope action = runEff (runFailure (runFileSystemIO scope (runDocumentPersistenceIO action))) >>= right
store :: DirectoryScope -> Eff (FlowStore : Host) a -> IO a
store scope = execute scope . runFlowStore (KnowledgeBase (Repository scope) WholeTree)

main :: IO ()
main = withSystemTempDirectory "kyyn-flow-store" $ \directory -> do
  scope <- right (directoryScope directory)
  let launch = FlowLaunch "revision" (String "request") (object []) Hosted
      start parent key = store scope (startInstance parent key launch) >>= right
      update op = store scope op >>= right
      readFlow identity = store scope (readInstance identity) >>= maybe (fail "Missing instance") pure
      wait identity = do
        _ <- update (beginAttempt identity)
        update (reportFrontier identity [("one",String "question"),("two",String "other")])
  parent <- start Nothing "parent"
  child <- start (Just parent.instanceId) "child-occurrence"
  replay <- start (Just parent.instanceId) "child-occurrence"
  assert (replay.instanceId == child.instanceId) "Child start was not idempotent"
  changed <- store scope (startInstance (Just parent.instanceId) "child-occurrence" launch { revision = "different" })
  assert (changed == Left StartConflict) "Changed child execution was silently reused"
  _ <- update (finishInstance parent.instanceId (Completed Null))
  activeChild <- readFlow child.instanceId
  assert (activeChild.status == Runnable) "Parent completion stopped child"
  _ <- wait child.instanceId
  queued <- update (queueDelivery child.instanceId "manual-1" "one" (ManualReply "cli") (Number 7))
  assert (queued.outcome == Nothing) "Ingress fulfilled a reply"
  before <- readFlow child.instanceId
  assert (before.status == Waiting) "Receipt woke a waiting flow before validation"
  _ <- update (resolveDelivery child.instanceId "manual-1" Accepted)
  after <- readFlow child.instanceId
  assert (after.status == Runnable && length [() | w <- after.waits, w.waitStatus == Open] == 1) "Partial reply did not wake independently"
  _ <- update (beginAttempt child.instanceId)
  _ <- update (reportFrontier child.instanceId [("two",String "other")])
  _ <- update (queueDelivery child.instanceId "conflict" "one" (ManualReply "cli") (Number 8))
  _ <- update (resolveDelivery child.instanceId "conflict" Conflicting)
  _ <- update (cancelInstance parent.instanceId FlowAndDescendants)
  preserved <- readFlow parent.instanceId
  cancelled <- readFlow child.instanceId
  assert (preserved.status == Finished (Completed Null)) "Subtree cancellation overwrote completed parent"
  assert (cancelled.status == Finished Cancelled) "Subtree cancellation missed active child"
  late <- update (queueDelivery child.instanceId "late" "two" (ManualReply "mcp") Null)
  assert (late.outcome == Just ClosedWait) "Late reply could reopen cancelled child"

  -- Ingress must complete even while a long attempt holds the same instance's journal.
  separate <- start Nothing "separate"
  _ <- wait separate.instanceId
  entered <- newEmptyMVar
  release <- newEmptyMVar
  let kb = KnowledgeBase (Repository scope) WholeTree
      identity = FlowJournalIdentity (flowInstanceIdText separate.instanceId) "revision" Null
  withAsync (execute scope (runFlowJournal kb identity (liftIO (putMVar entered () >> takeMVar release)))) $ \_ -> do
    takeMVar entered
    received <- timeout 2000000 (update (queueDelivery separate.instanceId "while-running" "one" (ManualReply "cli") Null))
    putMVar release ()
    assert (maybe False ((== Nothing) . (.outcome)) received) "Ingress blocked on attempt writer lock"
  _ <- update (cancelInstance separate.instanceId ThisFlow)
  resolved <- update (resolveDelivery separate.instanceId "while-running" Accepted)
  assert (resolved.status == Finished Cancelled && all ((== Just ClosedWait) . (.outcome)) resolved.deliveries)
    "Cancellation racing with fulfilment revived instance"

  withdrawal <- start Nothing "withdrawal"
  _ <- wait withdrawal.instanceId
  _ <- update (queueDelivery withdrawal.instanceId "not-yet-validated" "two" (ManualReply "cli") Null)
  _ <- update (beginAttempt withdrawal.instanceId)
  withdrawn <- update (reportFrontier withdrawal.instanceId [("one",String "question")])
  assert (length [() | w <- withdrawn.waits, w.waitStatus == Closed] == 1) "Absent wait remained open"
  lateValidation <- update (resolveDelivery withdrawal.instanceId "not-yet-validated" Accepted)
  assert (lateValidation.status == Waiting && all ((== Just ClosedWait) . (.outcome)) lateValidation.deliveries)
    "A withdrawn wait was revived by queued input"
  failed <- update (finishInstance withdrawal.instanceId (Failed [errorDiagnostic "test.failure" "Fixture failure"]))
  assert (length [() | w <- failed.waits, w.waitStatus == Open] == 1) "Failed attempt invented a new frontier"

  blocked <- start Nothing "blocked"
  _ <- update (blockInstance blocked.instanceId [errorDiagnostic "flow.execution-mismatch" "Pinned execution unavailable"])
  refused <- store scope (beginAttempt blocked.instanceId)
  assert (refused == Left ExecutionBlocked) "Blocked instance executed"
  _ <- update (cancelInstance blocked.instanceId ThisFlow)
  external <- store scope (startInstance Nothing "external" (FlowLaunch "revision" Null Null External)) >>= right
  rejected <- store scope (beginAttempt external.instanceId)
  assert (rejected == Left NotHosted) "Worker dispatched an external instance"
  -- Both serializations of child publication versus cancellation are valid.
  replicateM_ 12 $ do
    allItems <- store scope listInstances
    racer <- start Nothing ("race-" <> Text.pack (show (length allItems)))
    (created,_) <- concurrently
      (store scope (startInstance (Just racer.instanceId) "racing-child" launch))
      (update (cancelInstance racer.instanceId FlowAndDescendants))
    case created of
      Left CancelledAncestor -> pure ()
      Right item -> readFlow item.instanceId >>= \actual -> assert (actual.status == Finished Cancelled) "Racing child escaped cancellation"
      other -> fail ("Unexpected race result: " ++ show other)
  putStrLn "Flow catalog restart, independent ingress, partial replies and cancellation races pass."

assert :: Bool -> String -> IO ()
assert valid message = unless valid (fail message)
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
