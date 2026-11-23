{-# LANGUAGE DataKinds, OverloadedStrings, OverloadedRecordDot, TypeApplications #-}
-- Native journal boundaries: restart, immutable records, input/revision identity,
-- corruption and process-scoped locking. No providers or guest compilation.
module Main (main) where

import qualified Agentic as A
import qualified Agentic.Aeson as Aeson
import qualified Agentic.Codec as Codec
import qualified Agentic.Schema as Schema
import qualified Agentic.Journal as Journal
import qualified Agentic.Value as V
import Data.IORef
import qualified Data.List.NonEmpty as NonEmpty
import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (async, wait, poll)
import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=), encode)
import qualified Data.ByteString.Lazy as Lazy
import Kyyn.Plumbing.Protocol.Tool (ToolCall(..), JournalCall(..), decodeToolFrame, encodeJournalLookup)
import Kyyn.Plumbing.Protocol.PluginMessages (PluginFrame(..))
import qualified Data.ByteString.Char8 as Bytes
import Data.Either (isLeft)
import Effectful (Eff, IOE, runEff, liftIO)
import Kyyn.Domain.Git (Repository(..), TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (DirectoryScope, directoryScope)
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Capability.FlowJournal
import Kyyn.Porcelain.Interpreter.FlowJournal (runFlowJournal)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

assert :: String -> Bool -> IO ()
assert message ok = unless ok (fail message)

type Host = '[DocumentPersistence,FileSystem,Failure,IOE]
executeAt :: DirectoryScope -> Eff Host a -> IO a
executeAt scope action = runEff (runFailure (runFileSystemIO scope (runDocumentPersistenceIO action))) >>= either (fail . show) pure

main :: IO ()
main = withSystemTempDirectory "kyyn-flow-journal" $ \directory -> do
  let scope = either error id (directoryScope directory)
      execute = executeAt scope
      kb = KnowledgeBase (Repository scope) WholeTree
      identity = FlowJournalIdentity "flow-example" "revision-one" (object ["request" .= String "original"])
      key = object ["operation" .= String "wait", "index" .= (1 :: Int)]
      value = object ["result" .= String "reply"]
      journal = runFlowJournal kb identity
      file = directory </> ".kyyn/flows/flow-example/journal.json"
  let floating = object ["tag" .= String "Number", "value" .= String "4.0"]
      request = object ["tag" .= String "HostRequest", "id" .= String "1", "capability" .= String "flow-journal",
        "method" .= String "save", "arguments" .= object ["key" .= floating, "value" .= floating]]
  case decodeToolFrame (Lazy.toStrict (encode request)) of
    Right (HostRequest _ (ToolJournal (SaveJournal savedKey savedValue))) -> do
      assert "journal protocol preserves tagged keys and values" (savedKey == floating && savedValue == floating)
      execute (journal (saveCompletion savedKey savedValue))
      result <- execute (journal (lookupCompletion savedKey))
      assert "journal lookup preserves tagged result" (encodeJournalLookup result ==
        object ["tag" .= String "Some", "value" .= floating])
    _ -> fail "Journal protocol refused a valid value"
  missing <- execute (journal (lookupCompletion key))
  assert "fresh completion is absent" (missing == Nothing)
  execute (journal (saveCompletion key value))
  restored <- execute (journal (lookupCompletion key))
  assert "completion survives a fresh interpreter" (restored == Just value)
  before <- Bytes.readFile file
  execute (journal (saveCompletion key value))
  after <- Bytes.readFile file
  assert "duplicate save is a no-op" (before == after)
  refused <- runEff (runFailure (runFileSystemIO scope (runDocumentPersistenceIO
    (journal (saveCompletion key Null)))))
  assert "conflicting completion refused" (isLeft refused)
  intact <- execute (journal (lookupCompletion key))
  assert "refusal retains original" (intact == Just value)
  changed <- runEff (runFailure (runFileSystemIO scope (runDocumentPersistenceIO
    (runFlowJournal kb (identity { revision = "revision-two" }) (lookupCompletion key)))))
  assert "changed revision refused" (isLeft changed)
  inputChanged <- runEff (runFailure (runFileSystemIO scope (runDocumentPersistenceIO
    (runFlowJournal kb (identity { input = Null }) (lookupCompletion key)))))
  assert "changed initial request refused" (isLeft inputChanged)
  invalid <- runEff (runFailure (runFileSystemIO scope (runDocumentPersistenceIO
    (runFlowJournal kb (identity { namespace = "../escape" }) (lookupCompletion key)))))
  assert "path escape refused" (isLeft invalid)
  entered <- newEmptyMVar
  release <- newEmptyMVar
  owner <- async (execute (journal (liftIO (putMVar entered () >> takeMVar release))))
  takeMVar entered
  contender <- async (execute (journal (lookupCompletion key)))
  threadDelay 20000
  blocked <- poll contender
  assert "second writer must wait for held instance lock" (case blocked of Nothing -> True; _ -> False)
  putMVar release ()
  wait owner
  second <- wait contender
  assert "next writer reads the persisted completion" (second == Just value)
  effectCount <- newIORef (0 :: Int)
  let waitingIdentity = FlowJournalIdentity "waiting-flow" "fixed-code" (Number 7)
      codec = Codec.primitive Schema.SInteger V.Integer (\v -> case v of
        V.Integer n -> Right n
        _ -> Left "integer required")
      runtime = (A.runtimeWith (error . show))
        { A.journal = Just (Journal.Journal (Journal.JournalIdentity "waiting-flow" "fixed-code")
            (pure ()) (fmap (fmap Aeson.fromAeson) . lookupCompletion . Aeson.toAeson)
            (\k v -> saveCompletion (Aeson.toAeson k) (Aeson.toAeson v))) }
      flow = A.durably codec codec (\_ n -> liftIO (modifyIORef' effectCount (+1)) >> pure n)
        A.>>> A.await codec codec
      runWaiting = execute . runFlowJournal kb waitingIdentity
  first <- runWaiting (A.resumable runtime flow 7)
  pending <- case first of
    A.RunWaiting (one NonEmpty.:| []) -> pure one
    _ -> fail "Expected persisted wait"
  accepted <- runWaiting (A.fulfil runtime flow pending (V.Integer 9))
  assert "actual upstream fulfil saved in native store" (accepted == Right ())
  finished <- runWaiting (A.resumable runtime flow 7)
  count <- readIORef effectCount
  assert "actual upstream resume restores prior effect" (finished == A.RunFinished 9 && count == 1)
  Bytes.writeFile file "{incomplete"
  corrupted <- runEff (runFailure (runFileSystemIO scope (runDocumentPersistenceIO (journal (lookupCompletion key)))))
  assert "corrupt journal is never an empty store" (isLeft corrupted)
  putStrLn "Flow journal identity, immutable completion, restart and writer lock checks passed."
