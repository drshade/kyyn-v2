-- Real Nix recipe guest and native preparation/execution/rendering. The supplied
-- executable fixes compilation; selecting any other guest mode is rejected.
-- An empty captured evidence index supplies the nested connector callback.
-- Interactive attempts use fresh guest processes and the native journal; after
-- suspension any repeated connector read fails the test.
{-# LANGUAGE GHC2021, GADTs, OverloadedStrings, OverloadedRecordDot, DataKinds, TypeFamilies #-}
module Main (main) where

import Kyyn.Types.KnowledgeBase (Lifetime(..), InteractionBindings(..), ChildReference(..))
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Monad (unless, void)
import Data.Aeson (Value(..), object, (.=), (.:), withObject, toJSON)
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.Foldable as Foldable
import qualified Data.ByteString as Bytes
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text as Text
import Effectful (Eff, IOE, DispatchOf, Dispatch(..), runEff, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, interpose, localSeqUnlift)
import System.Directory (canonicalizePath, createDirectoryLink, removeDirectoryLink, createDirectoryIfMissing, createFileLink)
import System.Environment (getArgs)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.FlowClosure (FlowDeclaration(..))
import Kyyn.Porcelain.Protocol.FlowBundle (bundleValue, parseBundle)
import Kyyn.Domain.Model (ModelConfiguration(..), ModelProvider(..))
import Kyyn.Domain.Secret (secretName)
import Kyyn.Porcelain.Capability.FlowPreparation
import Kyyn.Porcelain.Interpreter.FlowPreparation (runFlowPreparation)
import qualified Kyyn.Domain.FlowInstance as Instance
import Kyyn.Domain.FlowBundleId (flowBundleIdText)
import Kyyn.Porcelain.Capability.FlowStore
import Kyyn.Porcelain.Interpreter.FlowStore (runFlowStore)
import Kyyn.Domain.RecipeRun (PreparedRecipeRun(..))
import qualified Kyyn.Domain.RecipeRun as Run
import Kyyn.Porcelain.Capability.FlowWorker
import Kyyn.Porcelain.Interpreter.FlowWorker (runFlowWorker)
import Kyyn.Domain.Git (Repository(..), TreePath(..), gitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.CompiledEntry (entryProgram, compiledEntries, invocationName)
import Kyyn.Porcelain.Capability.FlowJournal (FlowJournalIdentity(..))
import Kyyn.Porcelain.Interpreter.FlowJournal (runFlowJournal)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Plumbing.Protocol.Tool (encodeFlowValue, decodeFlowValue)
import Kyyn.Porcelain.Protocol.ToolBroker (executeInteractiveProgram, executeRecordedRecipeProgram)
import Kyyn.Porcelain.Capability.RecipeRunStore
import Kyyn.Porcelain.Interpreter.RecipeRunStore (runRecipeRunStore)
import Kyyn.Plumbing.Interpreter.AppendJournal (runAppendJournalIO)
import Kyyn.Domain.Contract (contractId, checkRootLayout)
import Kyyn.Domain.Guest (InspectedSchema(..), checkedEntries)
import Kyyn.Domain.Evidence (EvidenceSnapshotRef(..), ConnectorInstanceRef(..), EvidenceProducer(..), FetchId(..), FetchSummary(..))
import Kyyn.Domain.EvidenceIndex (EvidenceIndex(EvidenceIndex))
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.Path
import Kyyn.Domain.Plugin (packageIdentity, ConnectorTypeName(..))
import Kyyn.Domain.Root (SourceRoot(..), CheckedValue(..))
import qualified Kyyn.Domain.Recipe as R
import Kyyn.Domain.FactProposal (FactProposal(..), FactProposalStep(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Porcelain.Protocol.RecipeContracts (inspectRecipeContracts)
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import qualified Kyyn.Types.Guest as G
import Kyyn.Plumbing.Capability.BlobStorage (BlobStorage)
import Kyyn.Plumbing.Capability.Judgement (Judgement)
import Kyyn.Plumbing.Capability.ModelTurn (ModelTurn)
import Kyyn.Types.Wire (parseWire)
import Kyyn.Plumbing.Capability.GuestExecution (executeEntry)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestInspection (describeGuest)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Interpreter.GuestInspection (runGuestInspection)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore(..))
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.RootStore (readRootDefinition, materializeRoot)
import Kyyn.Porcelain.Capability.RecipeExecution (PreparedRecipe(..), prepareRecipeFlow, executeRecipeFlow)
import Kyyn.Porcelain.Capability.RecipeInspection (describeRecipe)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead)
import Kyyn.Porcelain.Interpreter.RecipeExecution (runRecipeExecution)
import Kyyn.Porcelain.Interpreter.RecipeInspection (runRecipeInspection)

main :: IO ()
main = do
  arguments <- getArgs
  executable <- case arguments of [selected] -> canonicalizePath selected; _ -> fail "Expected Nix recipe guest"
  let path = either error id . relativePath
  package <- mapM (\name -> (,) (path name) <$> Bytes.readFile ("tools/fixtures/captured-plugin/" ++ name))
    ["kyyn-plugin.dhall","src/Fixture/Plugin.hs"] >>= right . fileTree
  configuration <- Bytes.readFile "tools/fixtures/tool-guest/plugins/config/local-file.dhall"
  manifest <- Bytes.readFile "tools/fixtures/tool-guest/kb.dhall"
  code <- right (fileTree
    ([(path "flake.nix","{}"),(path "flake.lock","{}"),(path "kb.dhall",manifest),(path "plugins/config/local-file.dhall",configuration)] ++
     [(path ("plugins/packages/local-file/source/" ++ relativeName name),bytes) | (name,bytes) <- files package]))
  let baseProgram = CompiledProgram (BuildIdentity "fixture" "x86_64-linux" "fixture.drv" (takeDirectory (takeDirectory executable))) executable ".build/recipe-guest"
  withSystemTempDirectory "kyyn-native-recipe" $ \directory -> do
    scope <- right (directoryScope directory)
    let retention = directory ++ "/retained"
        program = baseProgram { retentionRoot = retention }
    createDirectoryLink baseProgram.identity.outputPath retention
    prepared <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection . fixedCompilation program . runPluginPreparation . runRootStore $ do
        description <- describeGuest program
        plugins <- case description of Left errors -> pure (Left errors); Right guest -> preparePluginsFromGuest code program guest
        definition <- readRootDefinition code
        pure (description,plugins,definition)
    (described,configured,defined) <- right prepared
    description <- right described
    plugins <- right configured
    definition <- right defined
    (schema,state) <- case [(root.contract,state.contract) | G.RecipeEntry _ "Flows.review" (G.RecipeContracts root _ state) <- checkedEntries description] of
      [selected] -> pure selected
      _ -> fail "Missing recipe"
    rootContract <- right (checkRootLayout schema)
    (plugin,payload) <- case [(name,payload) | PreparedPlugin (PreparedPackage name _ connectors) _ <- plugins,
        PreparedConnector {connectorType = ConnectorTypeName "Files",payloadContract = payload} <- connectors] of
      [selected] -> pure selected
      _ -> fail "Missing connector"
    let fetch = FetchId "fixture"
        snapshot = EvidenceSnapshotRef (ConnectorInstanceRef plugin "reader") (EvidenceProducer (packageIdentity package) (contractId payload)) fetch
        index = EvidenceIndex snapshot (FetchSummary fetch "now" 0 0 0 Nothing) payload mempty Nothing
        stateValue = CheckedValue (contractId state) (object ["runs" .= String "4"])
    result <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection . fixedCompilation program
      . unexpected @Judgement . unexpected @ModelTurn . unexpected @BlobStorage
      . capturedEvidence index . runPluginRead . runPluginPreparation . runRootStore
      . runAppendJournalIO . runRecipeRunStore (const (pure ())) . runRecipeInspection . runRecipeExecution $ do
        contracts <- inspectRecipeContracts (SourceRoot rootContract code definition [])
          [Fact (FactId "review") (R.ClosedRecipe Ordinary (FlowEntryRef "Flows.review"))]
        rendered <- describeRecipe (SourceRoot rootContract code definition []) Ordinary (FlowEntryRef "Flows.review") G.Tree
        stored <- materializeRoot rootContract code (R.KnowledgeBase (CheckedValue (contractId schema) (object ["items" .= ([] :: [Value])])) [])
        proposal <- case stored of
          Left errors -> pure (Left errors)
          Right root -> do
            preparation <- prepareRecipeFlow root (FlowEntryRef "Flows.review") stateValue Nothing
            case preparation of
              Left errors -> pure (Left errors)
              Right ready -> withRecipeRun (PreparedRecipeRun (KnowledgeBase (Repository scope) WholeTree)
                (R.RecipeId "review") (FlowEntryRef "Flows.review") (either error id (gitRevision (replicate 40 'a')))
                (entryProgram ready.entry).identity ready.graph ready.mermaid Nothing) (\writer -> executeRecipeFlow writer ready)
        pure (rendered,proposal,contracts)
    (rendered,proposal,contracts) <- right result
    states <- right contracts
    unless (case states of [(_,"Flows.State",actual)] -> actual == state; _ -> False)
      (fail "Private flow state contract/name differs from its guest descriptor")
    tree <- right rendered
    unless (not (Text.null tree)) (fail "Missing flow rendering")
    case proposal of
      Right (FactProposal [FactProposalStep _ [_]] (CheckedValue identity value))
        | identity == contractId state && value == object ["runs" .= String "5"] -> pure ()
      other -> fail ("Wrong native recipe result: " ++ show other)
    let declaration ident children = Fact (FactId ident) (R.ClosedRecipe
          (Interactive (InteractionBindings children)) (FlowEntryRef "Flows.waiting"))
        declarations = [declaration "parent" [ChildReference (R.RecipeId "child") (FlowEntryRef "Flows.waiting")],
          declaration "child" [ChildReference (R.RecipeId "child") (FlowEntryRef "Flows.waiting")]]
    preparedInteractive <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection . fixedCompilation program
      . runPluginPreparation . runFlowPreparation $
        prepareInteractiveFlow (either error id (gitRevision (replicate 40 'a'))) code declarations (R.RecipeId "parent") (Just "+1")
    interactive <- right preparedInteractive >>= right
    unless (interactive.request == String "1" &&
        map (\selected -> selected.declaration.recipe) interactive.bundle.closure == [R.RecipeId "parent",R.RecipeId "child"])
      (fail "Preparation lost request or declaration identities sharing one source")
    unless (all (\selected -> entryProgram selected.entry == program && not (Text.null selected.mermaid)) interactive.bundle.closure)
      (fail "Closure does not retain the checked executable and graph")
    let originalBundle = interactive.bundle
        capturedBundle = FlowBundle originalBundle.revision originalBundle.program originalBundle.guest originalBundle.closure originalBundle.plugins
          (Just (ModelConfiguration Anthropic "fixture-model" (either error id (secretName "model-credential"))))
        savedBundle = bundleValue capturedBundle
        credentialBytes = "PRIVATE-CREDENTIAL-BYTES-DO-NOT-CAPTURE"
    Bytes.writeFile (directory ++ "/private-credential") credentialBytes
    unless (not (TextEncoding.decodeUtf8 credentialBytes `Text.isInfixOf` Text.pack (show savedBundle)) &&
        "model-credential" `Text.isInfixOf` Text.pack (show savedBundle))
      (fail "Bundle lost secret reference or captured credential bytes")
    reopened <- right (parseEither parseBundle savedBundle)
    unless (bundleValue reopened == savedBundle && reopened.plugins == capturedBundle.plugins)
      (fail "Bundle reopening changed captured configuration or execution")
    let kbForCapture = KnowledgeBase (Repository scope) WholeTree
        store :: Eff '[FlowStore, DocumentPersistence, FileSystem, Failure, IOE] result -> IO (Either OperationalFailure result)
        store action = runEff . runFailure . runFileSystemIO scope . runDocumentPersistenceIO . runFlowStore kbForCapture $ action
    parent <- store (startPreparedInstance Nothing "parent-start" (PreparedFlow (R.RecipeId "parent") (String "1") capturedBundle)) >>= right >>= right
    parentBundleId <- case parent.launch.owner of Instance.Hosted identity _ -> pure identity; _ -> fail "Parent is not hosted"
    reopenedForChild <- store (readExecutionBundle parentBundleId) >>= right >>= right
    child <- store (startPreparedInstance (Just parent.instanceId) "child-start" (PreparedFlow (R.RecipeId "child") (String "2") reopenedForChild)) >>= right >>= right
    outside <- store (startPreparedInstance (Just parent.instanceId) "undeclared-child"
      (PreparedFlow (R.RecipeId "parent") (String "1") capturedBundle)) >>= right
    case outside of Left Instance.InvalidTransition{} -> pure (); _ -> fail "Started a child outside the declared set"
    different <- store (startPreparedInstance (Just parent.instanceId) "changed-child"
      (PreparedFlow (R.RecipeId "child") (String "1") originalBundle)) >>= right
    case different of Left Instance.InvalidTransition{} -> pure (); _ -> fail "Started child against different captured configuration"
    bundleId <- case parent.launch.owner of Instance.Hosted identity _ -> pure identity; _ -> fail "Parent is not hosted"
    childBundleId <- case child.launch.owner of Instance.Hosted identity _ -> pure identity; _ -> fail "Child is not hosted"
    unless (bundleId == childBundleId) (fail "Parent and child did not share the immutable bundle")
    fromDisk <- store (readExecutionBundle bundleId) >>= right >>= right
    unless (bundleValue fromDisk == savedBundle) (fail "Persisted bundle changed on reopen")
    let bundlePath = directory ++ "/.kyyn/flows/bundles/" ++ flowBundleIdText bundleId ++ ".json"
    originalBytes <- Bytes.readFile bundlePath
    Bytes.writeFile bundlePath "{}"
    corrupt <- store (readExecutionBundle bundleId) >>= right
    case corrupt of Left [Diagnostic _ "flow.bundle-identity" _ _] -> pure (); _ -> fail "Corrupt bundle was not refused"
    Bytes.writeFile bundlePath originalBytes
    removeDirectoryLink retention
    missing <- store (readExecutionBundle bundleId) >>= right
    case missing of Left [Diagnostic _ "flow.build-unavailable" _ _] -> pure (); _ -> fail "Missing retained build was not refused"
    _ <- store (cancelInstance parent.instanceId Instance.FlowAndDescendants) >>= right >>= right
    let otherOutput = directory ++ "/different-output"
    createDirectoryIfMissing True (otherOutput ++ "/bin")
    createFileLink baseProgram.executable (otherOutput ++ "/bin/kyyn-guest")
    createDirectoryLink otherOutput retention
    mismatch <- store (readExecutionBundle bundleId) >>= right
    case mismatch of Left [Diagnostic _ "flow.build-mismatch" _ _] -> pure (); _ -> fail "Retargeted retention link was accepted"
    removeDirectoryLink retention
    createDirectoryLink baseProgram.identity.outputPath retention
    -- Either catalog serialization must preserve a bundle used by a new start.
    raced <- newEmptyMVar
    void (forkIO (store (startPreparedInstance Nothing "racing-bundle-start"
      (PreparedFlow (R.RecipeId "parent") (String "3") capturedBundle)) >>= putMVar raced))
    _ <- store (clearInstances [parent.instanceId,child.instanceId]) >>= right >>= right
    survivor <- takeMVar raced >>= right >>= right
    _ <- store (readExecutionBundle bundleId) >>= right >>= right
    _ <- store (cancelInstance survivor.instanceId Instance.ThisFlow) >>= right >>= right
    _ <- store (clearInstances [survivor.instanceId]) >>= right >>= right
    cleared <- store (readExecutionBundle bundleId) >>= right
    case cleared of Left [Diagnostic _ "flow.bundle-missing" _ _] -> pure (); _ -> fail "Last clear retained an unreferenced bundle"
    invalidInteractive <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection . fixedCompilation program
      . runPluginPreparation . runFlowPreparation $
        prepareInteractiveFlow (either error id (gitRevision (replicate 40 'a'))) code declarations (R.RecipeId "parent") (Just "True")
    case invalidInteractive of
      Right (Left _) -> pure ()
      _ -> fail "Preparation accepted an invalid request"
    waitingEntry <- case filter ((== "$interactive.Flows.waiting") . invocationName) (compiledEntries program description) of
      [entry] -> pure entry
      _ -> fail "Missing waiting recipe"
    ordinaryEntry <- case filter ((== "$recipe.Flows.waitingOrdinary") . invocationName) (compiledEntries program description) of
      [entry] -> pure entry
      _ -> fail "Missing ordinary waiting recipe"
    ordinary <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
      . runDhallHandling . runGuestExecution [("LC_ALL","C.UTF-8")]
      . unexpected @Judgement . unexpected @ModelTurn . unexpected @BlobStorage
      . capturedEvidence index . runPluginRead . runAppendJournalIO . runRecipeRunStore (const (pure ())) $ do
        captured <- executeEntry ordinaryEntry (toJSON G.CaptureRecipeGraph)
        let (graph,mermaid) = either error id (parseWire captured >>= parseEither (withObject "captured graph" (\fields ->
              (,) <$> (fields .: "graph" >>= decodeFlowValue) <*> fields .: "mermaid")))
        withRecipeRun (PreparedRecipeRun (KnowledgeBase (Repository scope) WholeTree)
          (R.RecipeId "waitingOrdinary") (FlowEntryRef "Flows.waitingOrdinary")
          (either error id (gitRevision (replicate 40 'a'))) program.identity graph mermaid Nothing) $ \writer ->
            executeRecordedRecipeProgram writer ordinaryEntry plugins Nothing (toJSON (G.RunRecipe
              (object ["items" .= ([] :: [Value])]) (object []) (object ["runs" .= String "4"])))
    refused <- right ordinary
    unless (case refused of Left errors -> any (Text.isInfixOf "AwaitWithoutJournal" . (.message)) errors; Right _ -> False)
      (fail "Ordinary recipe was silently promoted to interactive execution")
    let kb = KnowledgeBase (Repository scope) WholeTree
        initial = String "4"
        resume = G.ResumeFlow "interactive-test" "pinned-fixture" initial
        identity = FlowJournalIdentity "interactive-test" "pinned-fixture" initial
        attempt first invocation = do
          outcome <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
            . runDhallHandling . runGuestExecution [("LC_ALL","C.UTF-8")]
            . unexpected @Judgement . unexpected @ModelTurn . unexpected @BlobStorage
            . (if first then capturedEvidence index else unexpected @EvidenceStore)
            . runPluginRead . runDocumentPersistenceIO . runFlowJournal kb identity $
              executeInteractiveProgram identity (\_ -> case invocation of
                G.FulfilFlow{} -> error "Fulfilment unexpectedly observed execution"
                _ -> pure ()) waitingEntry plugins Nothing (toJSON invocation)
          right outcome >>= right
    frontier <- attempt True resume >>= taggedValue "waiting"
    pending <- case frontier of
      Array values | [value] <- Foldable.toList values -> pure value
      _ -> fail "Expected one waiting point"
    let fulfil reply = G.FulfilFlow "interactive-test" "pinned-fixture" pending (encodeFlowValue reply)
    rejected <- attempt False (fulfil (String "not an integer"))
    _ <- taggedValue "refused" rejected >>= taggedValue "invalid"
    accepted <- attempt False (fulfil (Number 7))
    unless (accepted == object ["tag" .= String "accepted"]) (fail "Valid reply refused")
    duplicate <- attempt False (fulfil (Number 7))
    unless (duplicate == accepted) (fail "Identical fulfilment changed result")
    conflict <- attempt False (fulfil (Number 8))
    conflictBody <- taggedValue "refused" conflict
    unless (conflictBody == object ["tag" .= String "conflict"]) (fail "Conflict lost its refusal code")
    finished <- attempt False resume >>= taggedValue "finished"
    unless (finished == String "7") (fail ("Unexpected interactive result: " ++ show finished))
    -- Full hosted lifecycle, reopening a new guest process for each visit.
    let visit first selectedIdentity = visitWith False first selectedIdentity >>= right
        visitWith broken first selectedIdentity = do
          outcome <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
            . runDhallHandling . runGuestExecution [("LC_ALL","C.UTF-8")]
            . unexpected @Judgement . unexpected @ModelTurn . unexpected @BlobStorage
            . (if first then capturedEvidence index else unexpected @EvidenceStore)
            . runPluginRead . runDocumentPersistenceIO . runFlowStore kb
            . runAppendJournalIO . runRecipeRunStore (const (pure ()))
            . (if broken then failRunTerminal else id) . runFlowWorker kb $
              visitInstance selectedIdentity
          pure outcome
        inspect selectedIdentity = store (readInstance selectedIdentity) >>= right >>= maybe (fail "Missing instance") pure
        recording selectedIdentity = runEff (runFailure (runAppendJournalIO (runRecipeRunStore (const (pure ()))
          (readRecipeRun kb selectedIdentity Nothing 1000)))) >>= right
        clearRecording selectedIdentity = runEff (runFailure (runAppendJournalIO (runRecipeRunStore (const (pure ()))
          (clearRecipeRun kb selectedIdentity)))) >>= right
    hosted <- store (startPreparedInstance Nothing "worker" interactive) >>= right >>= right
    held <- newEmptyMVar
    releaseWriter <- newEmptyMVar
    released <- newEmptyMVar
    void (forkIO (runEff (runFailure (runFileSystemIO scope (runDocumentPersistenceIO
      (runFlowJournal kb (FlowJournalIdentity (Instance.flowInstanceIdText hosted.instanceId) hosted.launch.revision hosted.launch.request)
        (liftIO (putMVar held () >> takeMVar releaseWriter)))))) >>= putMVar released))
    takeMVar held
    busy <- visit False hosted.instanceId
    notStarted <- inspect hosted.instanceId
    unless (busy == WriterBusy && null notStarted.attempts && notStarted.status == Instance.Runnable)
      (fail "Busy worker started or recorded an attempt")
    putMVar releaseWriter ()
    _ <- takeMVar released >>= right
    firstVisit <- visit True hosted.instanceId
    unless (firstVisit == Advanced) (fail "Worker did not reach waiting frontier")
    waiting <- inspect hosted.instanceId
    (waitId,firstRun) <- case (waiting.status,waiting.waits,waiting.attempts) of
      (Instance.Waiting,[waitDescriptor],[attemptId]) -> pure (waitDescriptor.waitId,attemptId)
      _ -> fail "Worker did not persist frontier and attempt link"
    firstRecording <- recording firstRun
    unless (firstRecording.summary.status == Run.Suspended 1 && firstRecording.summary.header.instanceId == Just hosted.instanceId)
      (fail "Suspended attempt lost its outcome or instance link")
    idle <- visit False hosted.instanceId
    unless (idle == NoWork) (fail "Waiting instance ran without a reply")
    _ <- store (queueDelivery hosted.instanceId "bad" waitId (Instance.ManualReply "cli") (String "bad")) >>= right >>= right
    rejectedVisit <- visit False hosted.instanceId
    invalid <- inspect hosted.instanceId
    unless (rejectedVisit == NoWork && invalid.status == Instance.Waiting && invalid.attempts == [firstRun])
      (fail "Invalid reply woke or recorded an attempt")
    _ <- store (queueDelivery hosted.instanceId "answer" waitId (Instance.ManualReply "first") (Number 9)) >>= right >>= right
    _ <- store (queueDelivery hosted.instanceId "duplicate" waitId (Instance.ManualReply "second") (Number 9)) >>= right >>= right
    _ <- store (queueDelivery hosted.instanceId "conflict" waitId (Instance.ManualReply "third") (Number 10)) >>= right >>= right
    broken <- visitWith True False hosted.instanceId
    unless (case broken of Left _ -> True; _ -> False) (fail "Recording failure was swallowed")
    interruptedFlow <- inspect hosted.instanceId
    unless (interruptedFlow.status == Instance.Running && length interruptedFlow.waits == 1)
      (fail "Recording failure invented a terminal or removed the previous frontier")
    secondVisit <- visit False hosted.instanceId
    completedFlow <- inspect hosted.instanceId
    unless (secondVisit == Advanced && completedFlow.status == Instance.Finished (Instance.Completed (String "9")))
      (fail ("Worker did not resume from actual validated reply: " ++ show completedFlow))
    unless (map (.outcome) (drop 1 completedFlow.deliveries) == map Just [Instance.Accepted,Instance.Duplicate,Instance.Conflicting])
      (fail "Worker lost reply deduplication or conflict decisions")
    case completedFlow.waits of
      [waitDescriptor] | waitDescriptor.waitStatus == Instance.Answered (Instance.ManualReply "first") (Number 9) -> pure ()
      _ -> fail "Duplicate changed first reply provenance"
    secondRun <- case completedFlow.attempts of [_,_,attemptId] -> pure attemptId; _ -> fail "Missing resumed attempt"
    secondRecording <- recording secondRun
    unless (secondRecording.summary.status == Run.Returned && any
        (\(Run.SequencedRunEvent _ event) -> case event.body of
          Run.FlowObserved summary -> "restored" `Text.isInfixOf` Text.pack (show summary)
          _ -> False) secondRecording.events) (fail "Resumed recording did not preserve Restored")
    clearRecording firstRun
    retained <- inspect hosted.instanceId
    unless (retained.attempts == completedFlow.attempts) (fail "Clearing recording changed durable links")
    _ <- store (clearInstances [hosted.instanceId]) >>= right >>= right
    orphanRecording <- recording secondRun
    unless (orphanRecording.summary.status == Run.Returned) (fail "Recording required a retained instance")
    unavailable <- store (startPreparedInstance Nothing "worker-unavailable" interactive) >>= right >>= right
    removeDirectoryLink retention
    unavailableVisit <- visit False unavailable.instanceId
    unavailableState <- inspect unavailable.instanceId
    unless (unavailableVisit == Blocked && null unavailableState.attempts && not (null unavailableState.blocked))
      (fail "Missing build started a recording or lost blocked diagnostic")
    _ <- store (cancelInstance unavailable.instanceId Instance.ThisFlow) >>= right >>= right
    cancelledVisit <- visit False unavailable.instanceId
    unless (cancelledVisit == NoWork) (fail "Cancelled flow attempted execution")
    createDirectoryLink baseProgram.identity.outputPath retention
  putStrLn "Native recipe execution and rendering use the described guest, private state and nested captured connector."

fixedCompilation :: CompiledProgram -> Eff (GuestCompilation : es) a -> Eff es a
fixedCompilation program = interpret $ \_ (CompileGuest source) ->
  if selectedBuild source `elem` [RecipeEntries [ClosedFlow "Flows.review"], RecipeEntries [InteractiveFlow "Flows.waiting"]] then pure (Right program)
  else error "Recipe path attempted a separate plugin or host-generated build"

capturedEvidence :: EvidenceIndex -> Eff (EvidenceStore : es) a -> Eff es a
capturedEvidence index = interpret $ \_ operation -> case operation of
  OpenCurrentEvidence _ -> pure (Right (Just index))
  _ -> error "Unexpected evidence mutation or read in empty snapshot"

unexpected :: DispatchOf effect ~ Dynamic => Eff (effect : es) a -> Eff es a
unexpected = interpret (\_ _ -> error "Unexpected external interaction in recipe fixture")
right :: Show e => Either e a -> IO a
right = either (fail . show) pure

taggedValue :: Text.Text -> Value -> IO Value
taggedValue tag (Object fields)
  | Keys.lookup "tag" fields == Just (String tag), Just value <- Keys.lookup "value" fields = pure value
taggedValue tag value = fail ("Expected " ++ Text.unpack tag ++ ": " ++ show value)

-- Fail only the attempt's final recording write, after the guest has restored
-- and returned. The durable instance must remain resumable with its old frontier.
failRunTerminal :: (RecipeRunStore :> es, Failure :> es) => Eff es a -> Eff es a
failRunTerminal = interpose $ \env operation -> case operation of
  AppendRunEvent _ Run.RunReturned -> raiseFailure (Failure.StorageUnavailable
    (Failure.StorageDiagnostic Failure.WriteFile "fixture/events.jsonl" "injected recording failure"))
  AppendRunEvent writer event -> appendRunEvent writer event
  WithRecipeRun prepared use -> localSeqUnlift env $ \unlift -> withRecipeRun prepared (unlift . use)
  ListRecipeRuns kb selected -> listRecipeRuns kb selected
  ReadRecipeRun kb selected cursor limit -> readRecipeRun kb selected cursor limit
  ClearRecipeRun kb selected -> clearRecipeRun kb selected
