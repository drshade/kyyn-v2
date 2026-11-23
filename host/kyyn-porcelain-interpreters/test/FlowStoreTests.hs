-- Native catalog lifecycle: restart, parent/child independence, subtree races,
-- immutable start/reply identities, authoritative frontiers and ingress while a
-- guest journal lock is held. No guest build or provider service is involved.
{-# LANGUAGE DataKinds, GADTs, TypeApplications, OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where

import Control.Concurrent.Async (concurrently, withAsync, cancel)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Monad (unless, replicateM_, forM_)
import qualified Data.ByteString as Bytes
import qualified Effectful.State.Static.Local as State
import Effectful.Dispatch.Dynamic (interpret, localLiftUnlift)
import Data.Aeson (Value(..), object)
import qualified Data.Text as Text
import Effectful (Eff, IOE, runEff, liftIO, (:>), UnliftStrategy(..))
import System.IO.Temp (withSystemTempDirectory)
import GHC.Clock (getMonotonicTimeNSec)
import Text.Printf (printf)
import System.Timeout (timeout)
import Kyyn.Domain.CompiledProgram (CompiledProgram(..), BuildIdentity(..))
import Kyyn.Domain.CompiledEntry (compiledEntries)
import Kyyn.Domain.Contract (checkContract)
import Kyyn.Domain.Guest (checkGuest)
import Kyyn.Domain.FlowClosure (FlowDeclaration(..))
import Kyyn.Domain.FlowBundleId (identifyBundle)
import Kyyn.Types.KnowledgeBase (RecipeId(..), FlowEntryRef(..), InteractionBindings(..), ChildReference(..))
import Kyyn.Types.Contract (Description(UnitDescription))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import qualified Kyyn.Types.Guest as G
import Kyyn.Porcelain.Capability.FlowPreparation
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.FlowInstance
import Kyyn.Domain.Git (Repository(..), TreePath(..), gitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (DirectoryScope, directoryScope, relativePath)
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence(..), DocumentAccess(..), DocumentStamp(..))
import Kyyn.Plumbing.Capability.FileSystem (FileSystem, entryExists)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Capability.FlowStore
import Kyyn.Porcelain.Capability.FlowJournal (FlowJournalIdentity(FlowJournalIdentity), saveCompletion)
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
  let launch = FlowLaunch "revision" (object []) (Hosted (identifyBundle "fixture") (RecipeId "fixture"))
      start parent key = store scope (startPreparedInstance parent key preparedFixture) >>= right
      update :: Eff (FlowStore : Host) (Either FlowStoreProblem a) -> IO a
      update op = store scope op >>= right
      readFlow identity = store scope (readInstance identity) >>= maybe (fail "Missing instance") pure
      wait identity = do
        _ <- update (beginAttempt identity)
        update (reportFrontier identity [("one",String "question"),("two",String "other")])
  parent <- start Nothing "parent"
  child <- start (Just parent.instanceId) "child-occurrence"
  replay <- start (Just parent.instanceId) "child-occurrence"
  assert (replay.instanceId == child.instanceId) "Child start was not idempotent"
  raw <- store scope (startInstance Nothing "raw-hosted" launch)
  assert (case raw of Left InvalidTransition{} -> True; _ -> False) "Raw hosted start bypassed prepared authority"
  changed <- store scope (startPreparedInstance (Just parent.instanceId) "child-occurrence" (PreparedFlow preparedFixture.selected Null preparedFixture.bundle))
  assert (changed == Left StartConflict) "Changed child execution was silently reused"
  _ <- update (finishInstance parent.instanceId (Completed Null))
  terminalFrontier <- store scope (reportFrontier parent.instanceId [("late",String "late")])
  assert (terminalFrontier == Left AlreadyFinished) "Frontier after cancellation/completion was not terminal"
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
  _ <- update (queueDelivery child.instanceId "duplicate" "one" (ManualReply "cli") (Number 7))
  duplicate <- update (resolveDelivery child.instanceId "duplicate" Accepted)
  assert (duplicate.status == Waiting && any ((== Just Duplicate) . (.outcome)) duplicate.deliveries)
    "Duplicate reply woke an already waiting instance"
  _ <- update (queueDelivery child.instanceId "new-origin" "one" (ProviderReply "adapter" "another-event") (Number 7))
  newOrigin <- update (resolveDelivery child.instanceId "new-origin" Accepted)
  assert (newOrigin.status == Waiting && length [() | d <- newOrigin.deliveries, d.outcome == Just Duplicate] == 2)
    "Same reply from another origin remained unresolved"
  assert (any ((== Answered (ManualReply "cli") (Number 7)) . (.waitStatus)) newOrigin.waits)
    "Duplicate changed original reply origin"
  _ <- update (queueDelivery child.instanceId "conflict" "one" (ManualReply "cli") (Number 8))
  _ <- update (resolveDelivery child.instanceId "conflict" Conflicting)
  _ <- update (cancelInstance parent.instanceId FlowAndDescendants)
  preserved <- readFlow parent.instanceId
  cancelled <- readFlow child.instanceId
  assert (preserved.status == Finished (Completed Null)) "Subtree cancellation overwrote completed parent"
  assert (cancelled.status == Finished Cancelled) "Subtree cancellation missed active child"
  late <- update (queueDelivery child.instanceId "late" "two" (ManualReply "mcp") Null)
  assert (late.outcome == Just ClosedWait) "Late reply could reopen cancelled child"

  controller <- start Nothing "controller"
  controlled <- start (Just controller.instanceId) "controlled"
  grandchild <- start (Just controlled.instanceId) "grandchild"
  sibling <- start (Just controller.instanceId) "sibling"
  unrelated <- start Nothing "unrelated"
  visible <- update (readDescendant controller.instanceId grandchild.instanceId)
  assert (visible.instanceId == grandchild.instanceId) "Grandchild was not visible to its ancestor"
  forM_ [controlled.instanceId,controller.instanceId,sibling.instanceId,unrelated.instanceId] $ \target -> do
    deniedRead <- store scope (readDescendant controlled.instanceId target)
    deniedCancel <- store scope (cancelDescendant controlled.instanceId target FlowAndDescendants)
    assert (case (deniedRead,deniedCancel) of (Left InvalidTransition{},Left InvalidTransition{}) -> True; _ -> False)
      "Self, ancestor, sibling or unrelated root escaped child authority"
  _ <- update (cancelDescendant controller.instanceId controlled.instanceId ThisFlow)
  stillActive <- readFlow grandchild.instanceId
  assert (stillActive.status == Runnable) "ThisFlow cancellation stopped a grandchild"
  _ <- update (cancelDescendant controller.instanceId controlled.instanceId FlowAndDescendants)
  stoppedGrandchild <- readFlow grandchild.instanceId
  assert (stoppedGrandchild.status == Finished Cancelled) "Subtree cancellation missed a grandchild below a terminal child"
  _ <- update (clearInstances [grandchild.instanceId])
  clearedRead <- store scope (readDescendant controller.instanceId grandchild.instanceId)
  clearedCancel <- store scope (cancelDescendant controller.instanceId grandchild.instanceId ThisFlow)
  assert (clearedRead == Left MissingInstance && clearedCancel == Left MissingInstance)
    "Cleared child was conflated with an unrelated present instance"

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
  _ <- update (beginAttempt withdrawal.instanceId)
  interrupted <- readFlow withdrawal.instanceId
  assert (length [() | w <- interrupted.waits, w.waitStatus == Open] == 1) "Unfinished attempt withdrew prior waits"
  failed <- update (finishInstance withdrawal.instanceId (Failed [errorDiagnostic "test.failure" "Fixture failure"]))
  assert (null [() | w <- failed.waits, w.waitStatus == Open]) "Terminal failure retained open waits"

  blocked <- start Nothing "blocked"
  _ <- wait blocked.instanceId
  blockedWait <- update (blockInstance blocked.instanceId [errorDiagnostic "flow.execution-mismatch" "Pinned execution unavailable"])
  assert (blockedWait.status == Waiting) "Blocking changed execution status"
  refused <- store scope (beginAttempt blocked.instanceId)
  assert (refused == Left ExecutionBlocked) "Blocked instance executed"
  _ <- update (cancelInstance blocked.instanceId ThisFlow)
  external <- store scope (startInstance Nothing "external" (FlowLaunch "revision" Null External)) >>= right
  rejected <- store scope (beginAttempt external.instanceId)
  assert (rejected == Left NotHosted) "Worker dispatched an external instance"
  -- Both serializations of child publication versus cancellation are valid.
  replicateM_ 12 $ do
    allItems <- store scope listInstances
    racer <- start (Just controller.instanceId) ("race-" <> Text.pack (show (length allItems)))
    (created,_) <- concurrently
      (store scope (startPreparedInstance (Just racer.instanceId) "racing-child" preparedFixture))
      (update (cancelDescendant controller.instanceId racer.instanceId FlowAndDescendants))
    case created of
      Left CancelledAncestor -> pure ()
      Right item -> readFlow item.instanceId >>= \actual -> assert (actual.status == Finished Cancelled) "Racing child escaped cancellation"
      other -> fail ("Unexpected race result: " ++ show other)
  -- Clearing preserves every ancestor of an unfinished descendant.
  ancestor <- start Nothing "clear-ancestor"
  middle <- start (Just ancestor.instanceId) "clear-middle"
  leaf <- start (Just middle.instanceId) "clear-leaf"
  _ <- update (finishInstance ancestor.instanceId (Completed Null))
  _ <- update (finishInstance middle.instanceId (Completed Null))
  unfinished <- store scope (clearInstances [ancestor.instanceId,middle.instanceId])
  assert (case unfinished of Left InvalidTransition{} -> True; _ -> False) "Cleared ancestor of unfinished grandchild"
  _ <- update (beginAttempt leaf.instanceId)
  runningClear <- store scope (clearInstances [leaf.instanceId])
  assert (case runningClear of Left InvalidTransition{} -> True; _ -> False) "Cleared running/interrupted instance"
  _ <- update (finishInstance leaf.instanceId (Completed Null))
  _ <- update (clearInstances [middle.instanceId,leaf.instanceId])
  retainedParent <- readFlow ancestor.instanceId
  assert (retainedParent.status == Finished (Completed Null)) "Clearing finished children removed their retained parent"
  _ <- update (clearInstances [ancestor.instanceId])

  -- Interrupt clearing after its catalog commit, while journal deletion waits
  -- for an exiting attempt. A subsequent empty clear must sweep the orphan.
  orphan <- start Nothing "clear-orphan"
  _ <- update (finishInstance orphan.instanceId (Completed Null))
  journalEntered <- newEmptyMVar
  journalRelease <- newEmptyMVar
  let orphanIdentity = FlowJournalIdentity (flowInstanceIdText orphan.instanceId) "revision" Null
      journalPath = either error id (relativePath (".kyyn/flows/journals/" ++ Text.unpack (flowInstanceIdText orphan.instanceId)))
      awaitRemoval = do
        found <- store scope (readInstance orphan.instanceId)
        case found of Nothing -> pure (); Just _ -> threadDelay 1000 >> awaitRemoval
  withAsync (execute scope (runFlowJournal kb orphanIdentity (liftIO (putMVar journalEntered () >> takeMVar journalRelease)))) $ \_ -> do
    takeMVar journalEntered
    withAsync (store scope (clearInstances [orphan.instanceId])) $ \clearing -> do
      removed <- timeout 3000000 awaitRemoval
      assert (removed == Just ()) "Clearing did not commit before waiting for the journal lock"
      cancel clearing
    putMVar journalRelease ()
  exists <- execute scope (entryExists scope journalPath)
  assert exists "Interrupted clear unexpectedly deleted its locked journal"
  _ <- update (clearInstances [])
  swept <- execute scope (entryExists scope journalPath)
  assert (not swept) "Repeated clear leaked an orphan journal"
  collision <- runEff . runFailure . runFileSystemIO scope . State.evalState @CollisionRecord (Nothing,0)
    . collisionDocuments . runFlowStore kb $ do
      first <- startPreparedInstance Nothing "first" preparedFixture
      second <- startPreparedInstance Nothing "second" preparedFixture
      pure (first,second)
  (firstResult,secondResult) <- right collision
  first <- right firstResult
  second <- right secondResult
  assert (flowInstanceIdText first.instanceId == "00000001" && flowInstanceIdText second.instanceId == "00000002")
    "Colliding generated instance identity was published"
  -- A concrete baseline for the deliberately simple whole-journal replacement.
  -- 500 synthetic 1 KiB results; no timing assertion or provider latency.
  started <- getMonotonicTimeNSec
  execute scope (runFlowJournal kb (FlowJournalIdentity "size-baseline" "revision" Null)
    (forM_ [1..500 :: Int] (\n -> saveCompletion (String (Text.pack (show n))) (String (Text.replicate 1024 "x")))))
  ended <- getMonotonicTimeNSec
  printf "500 journal completions (1 KiB results): %.3f seconds\n" (fromIntegral (ended - started) / 1e9 :: Double)
  putStrLn "Flow catalog restart, independent ingress, partial replies and cancellation races pass."

assert :: Bool -> String -> IO ()
assert valid message = unless valid (fail message)
right :: Show e => Either e a -> IO a
right = either (fail . show) pure

-- Force the allocator to return the first ID twice before supplying a new one.
-- The store must retry within its catalog transaction, not publish duplicate IDs.
type CollisionRecord = (Maybe Bytes.ByteString,Int)
collisionDocuments :: State.State CollisionRecord :> es => Eff (DocumentPersistence : es) a -> Eff es a
collisionDocuments = interpret $ \env request -> case request of
  TryLockedDocument{} -> error "Unexpected nonblocking lock in this fixture"
  WithLockedDocument _ _ action ->
    localLiftUnlift env SeqUnlift $ \liftLocal unlift ->
      unlift (interpret (\_ operation -> liftLocal (collisionDocument operation)) action)
  where
  collisionDocument :: State.State CollisionRecord :> es => DocumentAccess m a -> Eff es a
  collisionDocument operation = do
    (document,count) <- State.get @CollisionRecord
    case operation of
      ReadCurrent -> pure document
      ReplaceCurrent bytes -> State.put (Just bytes,count)
      FreshStamp -> do
        State.put (document,count + 1)
        pure (DocumentStamp (if count < 2 then "00000001" else "00000002") "fixture")
      ClearCurrent -> error "Unexpected catalog deletion"

-- Synthetic, checked description: this suite tests store transactions without
-- invoking a compiler or guest. The native guest suite proves actual preparation.
preparedFixture :: PreparedFlow
preparedFixture = PreparedFlow (RecipeId "fixture") (object []) bundle
  where
    metadata = SchemaMetadata [] [] []
    contract = either (error . show) id (checkContract UnitDescription metadata)
    described = G.describeContract UnitDescription metadata []
    guest = either (error . show) id (checkGuest (G.GuestDescription
      [G.InteractiveEntry "$interactive.Flows.fixture" "Flows.fixture" (G.InteractiveContracts described described)] []))
    program = CompiledProgram (BuildIdentity "fixture" "fixture" "fixture.drv" "/fixture") "/fixture/bin/kyyn-guest" "/fixture"
    entry = case compiledEntries program guest of [selected] -> selected; _ -> error "Fixture entry missing"
    declaration = FlowDeclaration (RecipeId "fixture") (FlowEntryRef "Flows.fixture")
      (InteractionBindings [ChildReference (RecipeId "fixture") (FlowEntryRef "Flows.fixture")])
    bundle = FlowBundle (either error id (gitRevision (replicate 40 'a'))) program guest
      [PreparedFlowEntry declaration entry contract contract (object []) "fixture"] [] Nothing
