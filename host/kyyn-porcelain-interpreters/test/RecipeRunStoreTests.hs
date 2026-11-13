-- Native local recording lifecycle: visibility before append returns, exclusive
-- locks, cancellation, terminals, cursor reads and corrupt/partial records. No
-- guests, compiler or providers; installed recipe tests cover the integration.
{-# LANGUAGE DataKinds, OverloadedStrings, OverloadedRecordDot, TypeApplications #-}
module Main (main) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (async, cancel, wait)
import Control.Monad (unless, void)
import qualified Control.Exception as E
import Data.Aeson (Value(..), object, (.=))
import qualified Data.ByteString.Char8 as Bytes
import Data.Either (isLeft)
import Data.List (isInfixOf)
import Effectful (Eff, IOE, runEff, liftIO)
import Kyyn.Domain.CompiledProgram (BuildIdentity(..))
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Evolution (evolutionId)
import Kyyn.Domain.Git (Repository(..), TreePath(..), gitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (directoryScope)
import Kyyn.Domain.Recipe (RecipeId(..))
import Kyyn.Domain.RecipeRun
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.AppendJournal (AppendJournal)
import Kyyn.Plumbing.Interpreter.AppendJournal (runAppendJournalIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Capability.RecipeRunStore
import Kyyn.Porcelain.Interpreter.RecipeRunStore (runRecipeRunStore)
import System.Directory (doesDirectoryExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

check :: String -> Bool -> IO ()
check message condition = unless condition (fail message)
execute :: Eff '[RecipeRunStore, AppendJournal, Failure, IOE] a -> IO a
execute action = runEff (runFailure (runAppendJournalIO (runRecipeRunStore (const (pure ())) action))) >>= either (fail . show) pure

main :: IO ()
main = withSystemTempDirectory "kyyn-recordings-" $ \directory -> do
  let scope = either error id (directoryScope directory)
      kb = KnowledgeBase (Repository scope) WholeTree
      prepared = PreparedRecipeRun kb (RecipeId "review") (FlowEntryRef "Flows.review")
        (either error id (gitRevision (replicate 40 'a'))) (BuildIdentity "digest" "system" "build.drv" "output")
        (object ["upstream" .= String "graph"])
      draft = either error id (evolutionId "000001-review")
      event = FlowObserved (object ["opaque" .= String "summary"])
      eventFile identity = directory </> ".kyyn/runs" </> runIdText identity </> "events.jsonl"
  empty <- execute (listRecipeRuns kb Nothing)
  check "empty listing" (null empty)
  created <- doesDirectoryExist (directory </> ".kyyn/runs")
  check "read must not create runs" (not created)
  completed <- execute $ withRecipeRun prepared $ \writer@(RecipeRunWriter _ header) -> do
    _ <- appendRunEvent writer event
    -- Independent interpreter reads the bytes and probes the process-held lock.
    live <- liftIO $ execute (readRecipeRun kb header.runId Nothing 10)
    liftIO $ check "append wasn't visible or lock not active" (live.summary.status == Active && live.summary.eventCount == 1)
    refused <- liftIO $ E.try @E.IOException (execute (clearRecipeRun kb header.runId))
    liftIO $ check "active clear was allowed" (isLeft refused)
    _ <- appendRunEvent writer (RunCompleted draft)
    terminal <- liftIO $ execute (readRecipeRun kb header.runId Nothing 10)
    liftIO $ check "terminal must win over held lock" (terminal.summary.status == Completed draft)
    pure header
  first <- execute (readRecipeRun kb completed.runId Nothing 1)
  check "first cursor page" (first.next == Just 0 && first.more && first.summary.eventCount == 2)
  second <- execute (readRecipeRun kb completed.runId first.next 1)
  check "exclusive cursor or terminal" (second.next == Just 1 && not second.more && second.summary.status == Completed draft)
  one <- single first.events
  two <- single second.events
  check "timestamps/order" (one.elapsedNanos <= two.elapsedNanos && one.body == event && two.body == RunCompleted draft)
  interrupted <- execute $ withRecipeRun prepared $ \writer@(RecipeRunWriter _ header) -> appendRunEvent writer event >> pure header
  Bytes.appendFile (eventFile interrupted.runId) "{partial"
  partial <- execute (readRecipeRun kb interrupted.runId Nothing 10)
  check "partial tail or interrupted status" (partial.incompleteTail && partial.summary.status == Interrupted && partial.summary.eventCount == 1)
  Bytes.appendFile (eventFile interrupted.runId) "}\n"
  corrupt <- E.try @E.IOException (execute (readRecipeRun kb interrupted.runId Nothing 10))
  check "complete corrupt record lacked file/line diagnostic" (case corrupt of Left err -> "events.jsonl line 2" `isInfixOf` show err; _ -> False)
  execute (clearRecipeRun kb interrupted.runId)
  failed <- execute $ withRecipeRun prepared $ \writer@(RecipeRunWriter _ header) -> do
    _ <- appendRunEvent writer (RunFailed [errorDiagnostic "fixture" "typed failure"])
    pure header
  failedPage <- execute (readRecipeRun kb failed.runId Nothing 10)
  check "failed diagnostic didn't decode" (failedPage.summary.status == Failed)
  begun <- newEmptyMVar
  blocker <- newEmptyMVar
  cancelled <- async $ execute $ withRecipeRun prepared $ \(RecipeRunWriter _ header) -> do
    liftIO (putMVar begun header)
    liftIO (takeMVar blocker)
  cancellationHeader <- takeMVar begun
  cancel cancelled
  cancelledPage <- execute (readRecipeRun kb cancellationHeader.runId Nothing 10)
  check "cancellation terminal missing" (cancelledPage.summary.status == Cancelled)
  -- Returning a scoped handle does not preserve its write authority.
  stale <- execute $ withRecipeRun prepared pure
  staleResult <- E.try @E.IOException (execute (appendRunEvent stale event))
  check "stale writer accepted" (isLeft staleResult)
  -- Concurrent recordings get distinct locations; neither owns the other's lock.
  other <- async (execute (withRecipeRun prepared (\(RecipeRunWriter _ h) -> pure h)))
  this <- execute (withRecipeRun prepared (\(RecipeRunWriter _ h) -> pure h))
  that <- wait other
  check "concurrent run IDs collided" (this.runId /= that.runId)
  allRuns <- execute (listRecipeRuns kb (Just (RecipeId "absent")))
  check "recipe filter ignored" (null allRuns)
  Bytes.appendFile (eventFile completed.runId) "{}\n"
  afterTerminal <- E.try @E.IOException (execute (readRecipeRun kb completed.runId Nothing 10))
  check "event after terminal accepted" (isLeft afterTerminal)
  execute (clearRecipeRun kb completed.runId)
  gone <- doesDirectoryExist (directory </> ".kyyn/runs" </> runIdText completed.runId)
  check "clear left recording behind" (not gone)
  void (pure cancelled)
  putStrLn "Recipe recordings: visibility, locks, cursors, terminals, cancellation and corruption passed."

single :: [SequencedRunEvent] -> IO RunEvent
single [SequencedRunEvent _ event] = pure event
single _ = fail "Expected one event"
