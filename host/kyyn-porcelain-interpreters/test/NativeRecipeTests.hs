-- Real Nix recipe guest and native preparation/execution/rendering. The supplied
-- executable fixes compilation; selecting any other guest mode is rejected.
-- An empty captured evidence index supplies the nested connector callback.
-- Interactive attempts use fresh guest processes and the native journal; after
-- suspension any repeated connector read fails the test. Event adapters use an
-- injected clock and synthetic callbacks to test pacing, failures and ingress.
-- Short injected deadlines also exercise real subprocess cleanup and Waiting.
{-# LANGUAGE LambdaCase, DuplicateRecordFields, GHC2021, GADTs, OverloadedStrings, OverloadedRecordDot, DataKinds, TypeFamilies #-}
module Main (main) where

import Kyyn.Types.KnowledgeBase (Lifetime(..), InteractionBindings(..), ChildReference(..), EventReference(EventReference))
import Kyyn.Porcelain.Capability.FlowEvents (serviceEvents, EventVisit(..))
import Kyyn.Plumbing.Capability.Clock (Clock(..))
import Data.Time (UTCTime, addUTCTime)
import Kyyn.Porcelain.Capability.PluginEvent (PluginEvent(..))
import Kyyn.Porcelain.Interpreter.FlowEvents (runFlowEvents)
import Kyyn.Types.Plugin (RepeatSafety(..))
import Kyyn.Types.EventIdentity (EventIdentity(..))
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Monad (unless, void, when, forM)
import qualified Control.Exception as Exception
import System.IO.Error (isDoesNotExistError)
import System.Posix.Signals (signalProcess, nullSignal)
import System.Posix.Types (ProcessID)
import qualified System.Timeout as Timeout
import Kyyn.Plumbing.Capability.Deadline (Deadline(..), withinMicroseconds)
import Kyyn.Plumbing.Interpreter.Deadline (runDeadlineIO)
import Kyyn.Plumbing.Interpreter.HttpTransport (runHttpTransportWith)
import Kyyn.Plumbing.Capability.SecretStore (SecretStore)
import Kyyn.Plumbing.Interpreter.PluginInteraction (runWaitingIO)
import Kyyn.Porcelain.Interpreter.PluginEvent (runPluginEvent)
import Kyyn.Porcelain.Interpreter.FlowLocks (tryFlowAdapterLock)
import Data.Aeson (Value(..), object, (.=), (.:), withObject, toJSON, encode)
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.Foldable as Foldable
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.ByteString as Bytes
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text as Text
import Effectful (Eff, IOE, DispatchOf, Dispatch(..), runEff, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, interpose, localSeqUnlift)
import System.Directory (canonicalizePath, createDirectoryLink, removeDirectoryLink, createDirectoryIfMissing, createFileLink, doesPathExist, getPermissions, setPermissions, setOwnerExecutable)
import System.Environment (getArgs)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Plumbing.Capability.DocumentPersistence (DocumentPersistence)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.Diagnostic (Diagnostic(..), errorDiagnostic)
import Kyyn.Domain.FlowClosure (FlowDeclaration(..))
import Kyyn.Porcelain.Protocol.FlowBundle (bundleValue, parseBundle)
import Kyyn.Domain.Model (ModelConfiguration(..), ModelProvider(..))
import Kyyn.Domain.Secret (secretName)
import Kyyn.Porcelain.Capability.FlowPreparation
import qualified Kyyn.Porcelain.Capability.FlowPreparation as FlowPreparation
import Kyyn.Porcelain.Interpreter.FlowPreparation (runFlowPreparation)
import qualified Kyyn.Domain.FlowInstance as Instance
import Kyyn.Domain.FlowBundleId (flowBundleIdText)
import Kyyn.Porcelain.Capability.FlowStore
import Kyyn.Porcelain.Interpreter.FlowStore (runFlowStore)
import Kyyn.Domain.RecipeRun (PreparedRecipeRun(..))
import qualified Kyyn.Domain.RecipeRun as Run
import Kyyn.Porcelain.Capability.FlowWorker
import Kyyn.Porcelain.Interpreter.FlowControl (answerFlowControl)
import Kyyn.Porcelain.Interpreter.FlowWorker (runFlowWorker)
import Kyyn.Porcelain.Capability.PluginRead
import Kyyn.Types.Plugin (FetchError(..))
import Kyyn.Domain.Git (Repository(..), TreePath(..), gitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.CompiledEntry (entryProgram, compiledEntries, invocationName)
import Kyyn.Porcelain.Capability.FlowJournal (FlowJournalIdentity(..))
import Kyyn.Porcelain.Interpreter.FlowJournal (runFlowJournal)
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Plumbing.Protocol.Frame (Frame(..), jsonFrame, encodeFrame)
import Kyyn.Plumbing.Protocol.Tool (encodeFlowValue, decodeFlowValue, FlowControlCall(..))
import Kyyn.Porcelain.Protocol.ToolBroker (executeInteractiveProgram, executeRecordedRecipeProgram, executeToolProgram)
import Kyyn.Porcelain.Capability.RecipeRunStore
import Kyyn.Porcelain.Interpreter.RecipeRunStore (runRecipeRunStore)
import Kyyn.Plumbing.Interpreter.AppendJournal (runAppendJournalIO)
import Kyyn.Domain.Contract (contractId, checkRootLayout, descriptionOf)
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
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution(..), executeEntry, executeGuest, executeCompiled)
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
import qualified Kyyn.Porcelain.Capability.PluginPreparation as PluginPreparation
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
          (Interactive (InteractionBindings children [])) (FlowEntryRef "Flows.waiting"))
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
    let eventReference = EventReference "local-file" "Updates" "updates" "question"
        withEvent ref = [Fact (FactId "event") (R.ClosedRecipe
          (Interactive (InteractionBindings [] [ref])) (FlowEntryRef "Flows.waiting"))]
        captureEvent ref = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
          . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection . fixedCompilation program
          . runPluginPreparation . runFlowPreparation $
            prepareInteractiveFlow (either error id (gitRevision (replicate 40 'a'))) code (withEvent ref) (R.RecipeId "event") (Just "+1")
    declared <- captureEvent eventReference >>= right >>= right
    unless ([flow.declaration.bindings | flow <- declared.bundle.closure] == [InteractionBindings [] [eventReference]])
      (fail "Capture lost permitted event declaration")
    reopenedEvent <- right (parseEither parseBundle (bundleValue declared.bundle))
    unless (bundleValue reopenedEvent == bundleValue declared.bundle) (fail "Event declaration changed on reopen")
    Foldable.forM_ [EventReference "local-file" "Updates" "missing" "question",
      EventReference "local-file" "Updates" "updates" "missing",
      EventReference "local-file" "Other" "updates" "question"] $ \invalid -> do
        refusedCapture <- captureEvent invalid >>= right
        case refusedCapture of Left _ -> pure (); Right _ -> fail "Invalid event declaration captured"
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
    unless (length [() | PreparedPlugin _ instances <- reopened.plugins,
      ConfiguredConnector _ _ PreparedEventConnector{} (CheckedValue _ (String "10")) <- instances] == 1)
      (fail "Bundle lost configured event instance")
    let kbForCapture = KnowledgeBase (Repository scope) WholeTree
        store :: Eff '[FlowStore, DocumentPersistence, FileSystem, Failure, IOE] result -> IO (Either OperationalFailure result)
        store action = runEff . runFailure . runFileSystemIO scope . runDocumentPersistenceIO . runFlowStore kbForCapture $ action
    parent <- store (startPreparedInstance Nothing "parent-start" (PreparedFlow (R.RecipeId "parent") (String "1") capturedBundle)) >>= right >>= right
    parentBundleId <- case parent.launch.owner of Instance.Hosted identity _ -> pure identity; _ -> fail "Parent is not hosted"
    reopenedForChild <- store (readExecutionBundle parentBundleId) >>= right >>= right
    child <- store (startPreparedInstance (Just parent.instanceId) "child-start" (PreparedFlow (R.RecipeId "child") (String "2") reopenedForChild)) >>= right >>= right
    let eventKind = Instance.EventWait eventReference
    _ <- store (beginAttempt parent.instanceId) >>= right >>= right
    deniedFrontier <- store (reportFrontier parent.instanceId
      [("bare",Null,Instance.ReplyWait),("event",Null,eventKind)]) >>= right
    case deniedFrontier of Left Instance.InvalidTransition{} -> pure (); _ -> fail "Undeclared event frontier accepted"
    unchangedParent <- store (readInstance parent.instanceId) >>= right >>= maybe (fail "Missing parent") pure
    unless (null unchangedParent.waits) (fail "Unauthorized event partially published the frontier")
    eventInstance <- store (startPreparedInstance Nothing "event-start" declared) >>= right >>= right
    _ <- store (beginAttempt eventInstance.instanceId) >>= right >>= right
    eventFrontier <- store (reportFrontier eventInstance.instanceId [("event",Null,eventKind)]) >>= right >>= right
    unless (map (fmap (.dispatch) . (.adapter)) eventFrontier.waits == [Just Instance.Pending]) (fail "Dispatch was not persisted pending")
    reopenedInstance <- store (readInstance eventInstance.instanceId) >>= right >>= maybe (fail "Missing event instance") pure
    unless (reopenedInstance.waits == eventFrontier.waits) (fail "Event dispatch state changed on reopen")
    _ <- store (cancelInstance eventInstance.instanceId Instance.ThisFlow) >>= right >>= right
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
    metadata <- store (readBundleDescription bundleId) >>= right >>= right
    unless (bundleValue metadata == savedBundle) (fail "Missing executable prevented metadata inspection")
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
    -- A forged control request must still be refused by the ordinary/tool
    -- broker, even when an author bypasses the public startFlow combinator.
    controlContract <- case interactive.bundle.closure of selected:_ -> pure selected; _ -> fail "Missing flow contract"
    let forged = jsonFrame (Lazy.toStrict (encode (object
          ["tag" .= String "HostRequest","id" .= String "1","capability" .= String "flow-control","method" .= String "start",
           "arguments" .= object ["namespace" .= String "forged","key" .= String "forged","child" .= String "child",
             "inputContract" .= descriptionOf controlContract.inputContract,
             "outputContract" .= descriptionOf controlContract.outputContract,"input" .= String "1"]])))
    refusedControl <- runEff . runFailure . forgedControlGuest forged
      . unexpected @Judgement . unexpected @ModelTurn . unexpected @EvidenceStore . unexpected @PluginRead $
        executeToolProgram waitingEntry [] Nothing [] (object [])
    unless (case refusedControl of
      Left problem -> "only available during hosted interactive" `Text.isInfixOf` (Failure.operationalDiagnostic problem).message
      Right _ -> False) (fail "Ordinary broker accepted child control")
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
                _ -> pure ()) (\_ -> error "Unexpected child control") waitingEntry plugins Nothing (toJSON invocation)
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
    let visit first selectedIdentity = visitWith NoFault first selectedIdentity >>= right
        visitWith fault first selectedIdentity = workerWith fault first (visitInstance selectedIdentity)
        workerWith fault first operation = do
          outcome <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
            . runDhallHandling . (if fault == NoGuest then unexpected @GuestExecution else runGuestExecution [("LC_ALL","C.UTF-8")])
            . unexpected @Judgement . unexpected @ModelTurn . unexpected @BlobStorage
            . (if first then capturedEvidence index else unexpected @EvidenceStore)
            . runPluginRead . (case fault of PluginFault -> failPlugin True; ProtocolFault -> failPlugin False; _ -> id) . runDocumentPersistenceIO . runFlowStore kb
            . runAppendJournalIO . runRecipeRunStore (const (pure ()))
            . (if fault == RecordingFault then failRunTerminal else id) . runFlowWorker kb $
              operation
          pure outcome
        inspect selectedIdentity = store (readInstance selectedIdentity) >>= right >>= maybe (fail "Missing instance") pure
        recording selectedIdentity = runEff (runFailure (runAppendJournalIO (runRecipeRunStore (const (pure ()))
          (readRecipeRun kb selectedIdentity Nothing 1000)))) >>= right
        clearRecording selectedIdentity = runEff (runFailure (runAppendJournalIO (runRecipeRunStore (const (pure ()))
          (clearRecipeRun kb selectedIdentity)))) >>= right
    eventPrepared <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection . fixedCompilation program
      . runPluginPreparation . runFlowPreparation $
        prepareInteractiveFlow (either error id (gitRevision (replicate 40 'a'))) code
          [Fact (FactId "event") (R.ClosedRecipe (Interactive (InteractionBindings [] [eventReference])) (FlowEntryRef "Flows.eventWaiting"))]
          (R.RecipeId "event") (Just "\"Question\"")
    eventReady <- right eventPrepared >>= right
    let adapterPass safety fault selectedIdentity = fmap (fmap (.activity)) (eventPassAt 0 safety fault selectedIdentity)
        eventPassAt seconds safety fault selectedIdentity = runEff . runFailure . runFileSystemIO scope
          . fixedClock (addUTCTime seconds fixtureTime)
          . runDhallHandling . runDocumentPersistenceIO . runFlowStore kb
          . dispatchMetadata safety fault . syntheticDispatch fault selectedIdentity . runFlowEvents kb $
            serviceEvents selectedIdentity
        newEvent key = do
          item <- store (startPreparedInstance Nothing key eventReady) >>= right >>= right
          _ <- visit False item.instanceId
          waitingItem <- inspect item.instanceId
          case waitingItem.waits of
            [selectedWait] -> pure (item.instanceId,selectedWait.waitId)
            _ -> fail "Expected one event wait"
        adapterState selectedIdentity = do
          item <- inspect selectedIdentity
          case item.waits of
            [selectedWait] -> maybe (fail "Missing adapter") pure selectedWait.adapter
            _ -> fail "Expected one adapter"
    Foldable.forM_ [SafeToRepeat,RequireExplicitRetry] $ \safety ->
      Foldable.forM_ ["fetch","operational","cursor","commit"] $ \fault -> do
        (dispatchIdentity,_) <- newEvent (Text.pack (show safety ++ fault))
        outcome <- adapterPass safety fault dispatchIdentity >>= right
        unless (outcome == Blocked) (fail "Dispatch failure did not block")
        adapter <- adapterState dispatchIdentity
        unless (not (null adapter.dispatchProblems) && adapter.dispatch == Instance.Started)
          (fail "Dispatch failure was not durable")
        unless (any ((== "flow.dispatch-uncertain") . (.code)) adapter.dispatchProblems == (safety == RequireExplicitRetry))
          (fail "Post-start failure lost uncertainty warning")
        noSpin <- adapterPass safety "forbidden" dispatchIdentity >>= right
        unless (noSpin == NoWork) (fail "Dispatch block was retried automatically")
        _ <- store (retryInstance dispatchIdentity) >>= right >>= right
        success <- adapterPass safety "success" dispatchIdentity >>= right
        unless (success == Advanced) (adapterState dispatchIdentity >>= \adapterSnapshot -> fail ("Dispatch-only retry did not succeed: " ++ show (safety,fault,success,adapterSnapshot)))
        done <- adapterState dispatchIdentity
        unless (done.dispatch == Instance.DispatchCompleted && done.cursor == Just (String "10"))
          (fail "Successful dispatch did not retain cursor")
        _ <- adapterPass safety "poll-empty" dispatchIdentity >>= right
        again <- adapterPass safety "forbidden" dispatchIdentity >>= right
        unless (again == NoWork) (fail "Completed dispatch repeated")
        _ <- store (cancelInstance dispatchIdentity Instance.ThisFlow) >>= right >>= right
        pure ()
    Foldable.forM_ [SafeToRepeat,RequireExplicitRetry] $ \safety -> do
      (dispatchIdentity,key) <- newEvent (Text.pack ("interrupted-" ++ show safety))
      _ <- store (beginDispatch dispatchIdentity key) >>= right >>= right
      _ <- store (blockAttempt dispatchIdentity [errorDiagnostic "fixture" "unrelated attempt failure"]) >>= right >>= right
      blockedPass <- adapterPass safety "forbidden" dispatchIdentity >>= right
      unless (blockedPass == NoWork) (fail "Attempt-blocked instance dispatched")
      _ <- store (retryInstance dispatchIdentity) >>= right >>= right
      interrupted <- adapterState dispatchIdentity
      unless (interrupted.dispatch == Instance.Started) (fail "Unreported started reset during unrelated retry")
      resumed <- adapterPass safety (if safety == SafeToRepeat then "success" else "forbidden") dispatchIdentity >>= right
      unless (resumed == if safety == SafeToRepeat then Advanced else Blocked) (fail "Interrupted dispatch ignored repeat safety")
      _ <- store (cancelInstance dispatchIdentity Instance.ThisFlow) >>= right >>= right
      pure ()
    Foldable.forM_ ["cancel","manual"] $ \fault -> do
      (dispatchIdentity,_) <- newEvent (Text.pack ("during-" ++ fault))
      dispatchResult <- adapterPass SafeToRepeat fault dispatchIdentity >>= right
      unless (dispatchResult == Advanced) (fail "In-flight dispatchResult was lost")
      saved <- adapterState dispatchIdentity
      unless (saved.cursor == Just (String "10")) (fail "Closed wait discarded dispatch cursor")
      ignored <- adapterPass SafeToRepeat "forbidden" dispatchIdentity >>= right
      unless (ignored == NoWork) (fail "Closed wait invoked adapter")
    Foldable.forM_ ["poll-fail","poll-operational","poll-bad","poll-cursor"] $ \fault -> do
      (pollIdentity,_) <- newEvent (Text.pack fault)
      _ <- adapterPass SafeToRepeat "success" pollIdentity >>= right
      failedPoll <- eventPassAt 0 SafeToRepeat fault pollIdentity >>= right
      unless (failedPoll.activity == PollRetry (addUTCTime 2 fixtureTime) && not failedPoll.received) (fail "Poll failure was not reported")
      afterFailure <- inspect pollIdentity
      savedPoll <- adapterState pollIdentity
      unless (null afterFailure.deliveries && savedPoll.cursor == Just (String "10") && savedPoll.polling.consecutiveFailures == 1)
        (fail "Invalid batch advanced cursor or partially published arrivals")
      notDue <- eventPassAt 1 SafeToRepeat "forbidden" pollIdentity >>= right
      unless (notDue.activity == NoWork) (fail "Poll ran before its persisted due time")
      atDue <- eventPassAt 2 SafeToRepeat "poll-conflicts" pollIdentity >>= right
      unless (atDue.activity == Advanced && atDue.received) (fail "Poll did not recover at declared interval")
      savedBatch <- inspect pollIdentity
      unless (map (.outcome) savedBatch.deliveries == [Nothing,Just Instance.Conflicting])
        (fail "Provider duplicate/conflicting identity handling failed")
      recovered <- adapterState pollIdentity
      unless (recovered.cursor == Just (String "11") && recovered.polling.consecutiveFailures == 0 && null recovered.polling.problems)
        (fail "Successful poll did not reset error state with its cursor")
      duplicateBatch <- eventPassAt 4 SafeToRepeat "poll-conflicts" pollIdentity >>= right
      unless (not duplicateBatch.received) (fail "Repeated batch queued duplicate deliveries")
      repeatedBatch <- inspect pollIdentity
      unless (length repeatedBatch.deliveries == 2) (fail "Repeated poll grew duplicate history")
      _ <- visit False pollIdentity
      afterPoll <- inspect pollIdentity
      unless (case afterPoll.status of Instance.Finished Instance.Completed{} -> True; _ -> False)
        (fail "Provider arrival did not resume the real guest")
    Foldable.forM_ ["poll-cancel","poll-manual"] $ \fault -> do
      (pollIdentity,_) <- newEvent (Text.pack fault)
      _ <- adapterPass SafeToRepeat "success" pollIdentity >>= right
      _ <- eventPassAt 0 SafeToRepeat fault pollIdentity >>= right
      raceResult <- inspect pollIdentity
      savedPoll <- adapterState pollIdentity
      unless (savedPoll.cursor == Just (String "11")) (fail "Closed wait lost poll cursor")
      unless (if fault == "poll-cancel" then map (.outcome) raceResult.deliveries == [Just Instance.ClosedWait]
        else case raceResult.waits of [w] -> w.waitStatus == Instance.Answered (Instance.ReceivedFrom (Instance.ManualReply "cli")) (String "Manual") && map (.outcome) raceResult.deliveries == [Just Instance.Accepted,Just Instance.Conflicting]; _ -> False)
        (fail "Poll result overwrote cancellation or manual reply")
      noClosedPoll <- eventPassAt 10 SafeToRepeat "forbidden" pollIdentity >>= right
      unless (noClosedPoll.activity == NoWork) (fail "Closed wait was polled")
    -- Real subprocesses exercise silence, long Waiting and a blocked HTTP callback.
    -- The deadline is shortened by an injected interpreter only in this test.
    Foldable.forM_ [False,True] $ \pollingDeadline ->
      Foldable.forM_ ["silent","waiting","http"] $ \mode -> do
        let deadlineKey = Text.pack ("deadline-" ++ show pollingDeadline ++ "-" ++ mode)
        (timedIdentity,_) <- newEvent deadlineKey
        (followingIdentity,_) <- newEvent (deadlineKey <> "-next")
        when pollingDeadline $ do
          _ <- adapterPass SafeToRepeat "success" timedIdentity >>= right
          _ <- adapterPass SafeToRepeat "success" followingIdentity >>= right
          pure ()
        httpEntered <- newEmptyMVar
        httpBlocked <- newEmptyMVar
        let childPath = directory ++ "/" ++ Text.unpack deadlineKey ++ ".sh"
            pidPath = childPath ++ ".pid"
            callback = if mode == "http"
              then object ["tag" .= String "HostRequest","id" .= String "1","capability" .= String "http",
                "method" .= String "send","arguments" .= object ["method" .= String "GET","url" .= String "https://synthetic.invalid",
                  "headers" .= ([] :: [Value])]]
              else object ["tag" .= String "HostRequest","id" .= String "1","capability" .= String "waiting",
                "method" .= String "seconds","arguments" .= object ["seconds" .= String "3600"]]
            waitingFrame = Text.unpack (TextEncoding.decodeUtf8 (Bytes.concat (encodeFrame (jsonFrame (Lazy.toStrict (encode callback))))))
        writeFile childPath ("#!/bin/sh\nprintf '%s' \"$$\" > '" ++ pidPath ++ "'\n" ++
          (if mode /= "silent" then "printf '%s' '" ++ waitingFrame ++ "'\n" else "") ++
          "while read line; do :; done\n")
        permissions <- getPermissions childPath
        setPermissions childPath (setOwnerExecutable True permissions)
        deadlineResult <- Timeout.timeout 10000000 $ runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
          . runDeadlineIO . shortDeadlines . runWaitingIO . unexpected @SecretStore
          . runHttpTransportWith (\_ -> putMVar httpEntered () >> takeMVar httpBlocked)
          . runGuestExecution [("LC_ALL","C.UTF-8")] . rerouteGuest timedIdentity childPath
          . runDhallHandling . fixedClock fixtureTime . runDocumentPersistenceIO . runFlowStore kb
          . dispatchMetadata RequireExplicitRetry "success" . runPluginEvent . runFlowEvents kb $
            forM [timedIdentity,followingIdentity] serviceEvents
        reachedHttp <- not <$> isEmptyMVar httpEntered
        unless (reachedHttp == (mode == "http")) (fail "Deadline did not exercise the expected HTTP callback")
        visits <- maybe (fail "Deadline failed to bound callback and process cleanup") right deadlineResult
        unless (map (.activity) visits == [if pollingDeadline then PollRetry (addUTCTime 2 fixtureTime) else Blocked,Advanced])
          (fail ("Deadline did not continue to next instance: " ++ show visits))
        timedAdapter <- adapterState timedIdentity
        let timeoutProblems = if pollingDeadline then timedAdapter.polling.problems else timedAdapter.dispatchProblems
        unless (any ((== "flow.adapter-timeout") . (.code)) timeoutProblems)
          (fail "Timeout lost its diagnostic code")
        unless (pollingDeadline || any ((== "flow.dispatch-uncertain") . (.code)) timeoutProblems)
          (fail "Timed-out dispatch lost its duplicate-send warning")
        when pollingDeadline $ unless (timedAdapter.cursor == Just (String "10") && timedAdapter.polling.consecutiveFailures == 1)
          (fail "Poll timeout advanced cursor or lost retry state")
        pid <- read <$> readFile pidPath :: IO ProcessID
        alive <- Exception.try (signalProcess nullSignal pid) :: IO (Either Exception.IOException ())
        unless (either isDoesNotExistError (const False) alive) (fail "Timed-out guest is running or unreaped")
        unlocked <- runEff . runFailure . runDocumentPersistenceIO $ tryFlowAdapterLock kb timedIdentity (pure ())
        unless (unlocked == Right (Just ())) (fail "Timed-out adapter retained its lock")
        _ <- store (cancelInstance timedIdentity Instance.ThisFlow) >>= right >>= right
        _ <- store (cancelInstance followingIdentity Instance.ThisFlow) >>= right >>= right
        pure ()
    Foldable.forM_ [("manual-first",Instance.ManualReply "cli",Instance.ProviderReply eventReference (EventIdentity "provider-event")),
      ("provider-first",Instance.ProviderReply eventReference (EventIdentity "provider-event"),Instance.ManualReply "cli")] $ \(key,firstOrigin,secondOrigin) -> do
      eventHosted <- store (startPreparedInstance Nothing key eventReady) >>= right >>= right
      _ <- visit False eventHosted.instanceId
      eventWaiting <- inspect eventHosted.instanceId
      eventWait <- case eventWaiting.waits of [selected] -> pure selected; _ -> fail "Event wait not published"
      unless (fmap (.dispatch) eventWait.adapter == Just Instance.Pending) (fail "Event dispatch did not remain pending")
      _ <- store (queueDelivery eventHosted.instanceId "invalid" eventWait.waitId (Instance.ReceivedFrom firstOrigin) (Number 7)) >>= right >>= right
      _ <- visitWith NoGuest False eventHosted.instanceId >>= right
      stillWaiting <- inspect eventHosted.instanceId
      unless (stillWaiting.status == Instance.Waiting && stillWaiting.attempts == eventWaiting.attempts &&
        (case stillWaiting.deliveries of
          [delivery] -> case delivery.outcome of Just Instance.Invalid{} -> True; _ -> False
          _ -> False))
        (fail "Invalid event payload entered guest execution")
      _ <- store (queueDelivery eventHosted.instanceId "first" eventWait.waitId (Instance.ReceivedFrom firstOrigin) (String "Answer")) >>= right >>= right
      _ <- store (queueDelivery eventHosted.instanceId "same" eventWait.waitId (Instance.ReceivedFrom secondOrigin) (String "Answer")) >>= right >>= right
      _ <- store (queueDelivery eventHosted.instanceId "different" eventWait.waitId (Instance.ReceivedFrom secondOrigin) (String "Different")) >>= right >>= right
      _ <- visit False eventHosted.instanceId
      eventFinished <- inspect eventHosted.instanceId
      unless (map (.outcome) (drop 1 eventFinished.deliveries) == map Just [Instance.Accepted,Instance.Duplicate,Instance.Conflicting])
        (fail "Event origin affected payload deduplication")
      unless (map (.waitStatus) eventFinished.waits == [Instance.Answered (Instance.ReceivedFrom firstOrigin) (String "Answer")])
        (fail "Event duplicate replaced first accepted provenance")
      unless (map (.origin) (drop 1 eventFinished.deliveries) == map Instance.ReceivedFrom [firstOrigin,secondOrigin,secondOrigin])
        (fail "Event delivery history lost actual ingress provenance")
      case eventFinished.status of
        Instance.Finished (Instance.Completed value) -> do
          replyValue <- right (parseEither (withObject "received reply" (.: "value")) value)
          unless (replyValue == String "Answer") (fail "Guest received wrong event reply")
        _ -> fail "Typed event did not complete"
    let missingId = either error id (Instance.flowInstanceId "never-started")
    missingBusy <- workerWith NoFault False ((\busyWriter -> if busyWriter then WriterBusy else NoWork) <$> writerBusy missingId) >>= right
    missingVisit <- visit False missingId
    missingLock <- doesPathExist (directory ++ "/.kyyn/flows/journals/never-started.lock")
    missingDirectory <- doesPathExist (directory ++ "/.kyyn/flows/journals/never-started")
    unless (missingBusy == NoWork && missingVisit == NoWork && not missingLock && not missingDirectory)
      (fail "Inspection or visit allocated a missing instance journal or lock")
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
    _ <- store (queueDelivery hosted.instanceId "bad" waitId (Instance.ReceivedFrom (Instance.ManualReply "cli")) (String "bad")) >>= right >>= right
    rejectedVisit <- visit False hosted.instanceId
    invalid <- inspect hosted.instanceId
    unless (rejectedVisit == NoWork && invalid.status == Instance.Waiting && invalid.attempts == [firstRun])
      (fail "Invalid reply woke or recorded an attempt")
    _ <- store (queueDelivery hosted.instanceId "answer" waitId (Instance.ReceivedFrom (Instance.ManualReply "first")) (Number 9)) >>= right >>= right
    _ <- store (queueDelivery hosted.instanceId "duplicate" waitId (Instance.ReceivedFrom (Instance.ManualReply "second")) (Number 9)) >>= right >>= right
    _ <- store (queueDelivery hosted.instanceId "conflict" waitId (Instance.ReceivedFrom (Instance.ManualReply "third")) (Number 10)) >>= right >>= right
    broken <- visitWith RecordingFault False hosted.instanceId
    unless (case broken of Left _ -> True; _ -> False) (fail "Recording failure was swallowed")
    interruptedFlow <- inspect hosted.instanceId
    unless (interruptedFlow.status == Instance.Running && length interruptedFlow.waits == 1)
      (fail "Recording failure invented a terminal or removed the previous frontier")
    refusedRetry <- visit False hosted.instanceId
    stillInterrupted <- inspect hosted.instanceId
    unless (refusedRetry == Blocked && stillInterrupted.attempts == interruptedFlow.attempts)
      (fail "Reported failure was automatically retried")
    _ <- store (retryInstance hosted.instanceId) >>= right >>= right
    secondVisit <- visit False hosted.instanceId
    completedFlow <- inspect hosted.instanceId
    unless (secondVisit == Advanced && completedFlow.status == Instance.Finished (Instance.Completed (String "9")))
      (fail ("Worker did not resume from actual validated reply: " ++ show completedFlow))
    unless (map (.outcome) (drop 1 completedFlow.deliveries) == map Just [Instance.Accepted,Instance.Duplicate,Instance.Conflicting])
      (fail "Worker lost reply deduplication or conflict decisions")
    case completedFlow.waits of
      [waitDescriptor] | waitDescriptor.waitStatus == Instance.Answered (Instance.ReceivedFrom (Instance.ManualReply "first")) (Number 9) -> pure ()
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
    failing <- store (startPreparedInstance Nothing "worker-failing" interactive) >>= right >>= right
    failedVisit <- visitWith PluginFault True failing.instanceId >>= right
    failedInstance <- inspect failing.instanceId
    unless (failedVisit == Advanced && case failedInstance.status of
        Instance.Finished (Instance.Failed _) -> True; _ -> False)
      (fail "Returned guest FetchError did not finish the logical instance")
    failedRun <- case failedInstance.attempts of [attemptId] -> recording attemptId; _ -> fail "Missing failed attempt"
    unless (failedRun.summary.status == Run.Failed) (fail "Returned failure lost its attempt terminal")
    protocolFailure <- store (startPreparedInstance Nothing "worker-protocol-failure" interactive) >>= right >>= right
    protocolVisit <- visitWith ProtocolFault True protocolFailure.instanceId >>= right
    protocolState <- inspect protocolFailure.instanceId
    unless (protocolVisit == Blocked && protocolState.retryRequired && protocolState.status == Instance.Running)
      (fail "Host failure was mistaken for an authoritative guest failure")
    secondProtocolVisit <- visit False protocolFailure.instanceId
    sameProtocolState <- inspect protocolFailure.instanceId
    unless (secondProtocolVisit == Blocked && sameProtocolState.attempts == protocolState.attempts)
      (fail "Deterministic failure re-executed on polling")
    _ <- store (cancelInstance protocolFailure.instanceId Instance.ThisFlow) >>= right >>= right
    cancelledBlocked <- visit False protocolFailure.instanceId
    unless (cancelledBlocked == NoWork) (fail "Cancelled blocked instance still requested work")
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
    -- Crash precisely after child publication and before the durable completion
    -- is saved. A new guest process must recover the same child, then replay it.
    let parentDeclarations = [Fact (FactId "coordinator") (R.ClosedRecipe
          (Interactive (InteractionBindings [ChildReference (R.RecipeId "child") (FlowEntryRef "Flows.waiting")] []))
          (FlowEntryRef "Flows.parentWaiting")), declaration "child" []]
    preparedParent <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection . fixedCompilation program
      . runPluginPreparation . runFlowPreparation $
        prepareInteractiveFlow (either error id (gitRevision (replicate 40 'a'))) code parentDeclarations (R.RecipeId "coordinator") (Just "+1")
    preparedChildStart <- right preparedParent >>= right
    coordinator <- store (startPreparedInstance Nothing "crash-window" preparedChildStart) >>= right >>= right
    coordinatorEntry <- case preparedChildStart.bundle.closure of
      selected:_ -> pure selected.entry
      _ -> fail "Missing coordinator entry"
    let coordinatorIdentity = FlowJournalIdentity (Instance.flowInstanceIdText coordinator.instanceId) coordinator.launch.revision coordinator.launch.request
        childAttempt crash restored = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
          . runGuestExecution [("LC_ALL","C.UTF-8")]
          . unexpected @Judgement . unexpected @ModelTurn . unexpected @EvidenceStore . unexpected @PluginRead
          . runDocumentPersistenceIO . runFlowStore kb . runFlowJournal kb coordinatorIdentity $
            executeInteractiveProgram coordinatorIdentity (const (pure ())) (\call -> do
              when restored (error "Restored start reached the host")
              value <- answerFlowControl coordinator.instanceId preparedChildStart.bundle call
              if crash then raiseFailure (Failure.StorageUnavailable
                (Failure.StorageDiagnostic Failure.WriteFile "fixture/after-publication" "injected interruption before journal save"))
                else pure value) coordinatorEntry [] Nothing
                (toJSON (G.ResumeFlow coordinatorIdentity.namespace coordinatorIdentity.revision coordinatorIdentity.input))
        children = filter ((== Just coordinator.instanceId) . (.parent)) <$> (store listInstances >>= right)
    childContract <- case [entry | entry <- preparedChildStart.bundle.closure, entry.declaration.recipe == R.RecipeId "child"] of
      [entry] -> pure entry
      _ -> fail "Missing captured child contract"
    let control inputDescription outputDescription inputValue = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
          . runGuestExecution [("LC_ALL","C.UTF-8")] . runDocumentPersistenceIO . runFlowStore kb $
            answerFlowControl coordinator.instanceId preparedChildStart.bundle
              (StartChildCall coordinatorIdentity.namespace "invalid-child" (R.RecipeId "child") inputDescription outputDescription inputValue)
    invalidChild <- control (descriptionOf childContract.inputContract) (descriptionOf childContract.outputContract) (String "not-an-integer") >>= right
    case invalidChild of Object fields | Keys.lookup "tag" fields == Just (String "Left") -> pure (); _ -> fail "Invalid child input was not a typed refusal"
    parentContract <- case preparedChildStart.bundle.closure of entry:_ -> pure entry; _ -> fail "Missing captured parent"
    wrongOutput <- control (descriptionOf childContract.inputContract) (descriptionOf parentContract.outputContract) (String "1") >>= right
    case wrongOutput of Object fields | Just (String message) <- Keys.lookup "value" fields,
                                        "output contract mismatch" `Text.isInfixOf` message -> pure ()
                        _ -> fail "Wrong output witness was not refused"
    noChildren <- children
    unless (null noChildren) (fail "Invalid child request published an instance")
    interruptedStart <- childAttempt True False
    case interruptedStart of Left _ -> pure (); Right _ -> fail "Publication interruption was not injected"
    firstChildren <- children
    publishedChild <- case firstChildren of [only] -> pure only; _ -> fail "Interruption did not leave exactly one published child"
    recovered <- childAttempt False False >>= right >>= right >>= taggedValue "finished"
    replayed <- childAttempt False True >>= right >>= right >>= taggedValue "finished"
    afterReplay <- children
    unless (recovered == String (Instance.flowInstanceIdText publishedChild.instanceId) && replayed == recovered && length afterReplay == 1)
      (fail "Replay changed or duplicated the published child")
    let controlChild call = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
          . runGuestExecution [("LC_ALL","C.UTF-8")] . runDocumentPersistenceIO . runFlowStore kb $
            answerFlowControl coordinator.instanceId preparedChildStart.bundle call
        expectRefused label action = do
          value <- action >>= right
          case value of
            Object fields | Keys.lookup "tag" fields == Just (String "Left") -> pure ()
            _ -> fail label
    expectRefused "Inspection accepted a self handle" (controlChild
      (InspectChildCall (Instance.flowInstanceIdText coordinator.instanceId) (descriptionOf childContract.outputContract)))
    expectRefused "Inspection accepted a wrong output witness" (controlChild
      (InspectChildCall (Instance.flowInstanceIdText publishedChild.instanceId) (descriptionOf parentContract.outputContract)))
    expectRefused "Cancellation accepted a wrong output witness" (controlChild
      (CancelChildCall (Instance.flowInstanceIdText publishedChild.instanceId) (descriptionOf parentContract.outputContract) True))
    unchangedChild <- inspect publishedChild.instanceId
    unless (unchangedChild.status == Instance.Runnable) (fail "Refused cancellation changed the child")
    _ <- store (beginAttempt coordinator.instanceId) >>= right >>= right
    _ <- store (finishInstance coordinator.instanceId (Instance.Completed recovered)) >>= right >>= right
    _ <- visit True publishedChild.instanceId
    childState <- inspect publishedChild.instanceId
    unless (childState.status == Instance.Waiting) (fail "Completed parent prevented independent child execution")
    expectRefused "Completed parent cancelled its independent child" (controlChild
      (CancelChildCall (Instance.flowInstanceIdText publishedChild.instanceId)
        (descriptionOf childContract.outputContract) False))
    independentChild <- inspect publishedChild.instanceId
    unless (independentChild.status == Instance.Waiting) (fail "Refused terminal caller cancellation changed the child")
    _ <- store (cancelInstance publishedChild.instanceId Instance.ThisFlow) >>= right >>= right
    _ <- store (clearInstances [publishedChild.instanceId]) >>= right >>= right
    clearedInspection <- controlChild (InspectChildCall (Instance.flowInstanceIdText publishedChild.instanceId)
      (descriptionOf childContract.outputContract)) >>= right
    case clearedInspection of
      Object fields | Just (String message) <- Keys.lookup "value" fields, "cleared" `Text.isInfixOf` message -> pure ()
      _ -> fail "Cleared child inspection lost its distinct typed refusal"
  putStrLn "Native recipe execution and rendering use the described guest, private state and nested captured connector."

fixedCompilation :: CompiledProgram -> Eff (GuestCompilation : es) a -> Eff es a
fixedCompilation program = interpret $ \_ (CompileGuest source) ->
  if selectedBuild source `elem` [RecipeEntries [ClosedFlow "Flows.review"], RecipeEntries [InteractiveFlow "Flows.waiting"], RecipeEntries [InteractiveFlow "Flows.eventWaiting"],
    RecipeEntries [InteractiveFlow "Flows.parentWaiting", InteractiveFlow "Flows.waiting"]] then pure (Right program)
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

data WorkerFault = NoFault | NoGuest | RecordingFault | PluginFault | ProtocolFault deriving Eq

failPlugin :: PluginRead :> es => Bool -> Eff es a -> Eff es a
failPlugin authoritative = interpose $ \_ operation -> case operation of
  LoadCapturedInput selected contract -> loadCapturedInput selected contract
  ExecuteCapturedMethod{} -> pure (if authoritative then Right (Left (FetchError "fixture refusal"))
    else Left [errorDiagnostic "tool.failed" "Host-side fixture failure with the same diagnostic code"])
  ResolveCapturedBlobs captures contract value -> resolveCapturedBlobs captures contract value

forgedControlGuest :: Frame -> Eff (GuestExecution : es) a -> Eff es a
forgedControlGuest frame = interpret $ \env operation -> case operation of
  ExecuteGuest _ _ respond -> localSeqUnlift env $ \unlift -> unlift (respond frame) >> error "Forged control request was accepted"
  ExecuteCompiled{} -> error "Unexpected compiled execution"

-- Override only provider metadata/faults: native preparation and the durable
-- store remain real. No external provider or poll is available in this harness.
dispatchMetadata :: FlowStore :> es => RepeatSafety -> String -> Eff es a -> Eff es a
dispatchMetadata safety fault = interpose $ \_ operation -> case operation of
  ReadExecutionBundle identity -> fmap (fmap (\bundle -> bundle {FlowPreparation.plugins = map plugin bundle.plugins})) (readExecutionBundle identity)
  CompleteDispatch _ _ _ | fault == "commit" -> pure (Left (Instance.InvalidTransition "injected completion failure"))
  BeginPoll identity key now interval -> beginPoll identity key now interval
  CompletePoll identity key arrivals cursor -> completePoll identity key arrivals cursor
  FailPoll identity key problems -> failPoll identity key problems
  ReadInstance identity -> readInstance identity
  BeginDispatch identity key -> beginDispatch identity key
  CompleteDispatch identity key value -> completeDispatch identity key value
  BlockDispatch identity key problems -> blockDispatch identity key problems
  CancelInstance identity extent -> cancelInstance identity extent
  QueueDelivery identity (Just delivery) key origin value -> queueDelivery identity delivery key origin value
  QueueDelivery identity Nothing key origin value -> queueNewDelivery identity key origin value
  ResolveDelivery identity delivery outcome -> resolveDelivery identity delivery outcome
  _ -> error "Unexpected adapter store operation"
  where
    plugin (PreparedPlugin (PreparedPackage name identity connectors) instances) =
      PreparedPlugin (PreparedPackage name identity (map connector connectors)) (map configured instances)
    configured (ConfiguredConnector name binding selected config) = ConfiguredConnector name binding (connector selected) config
    connector selected@PreparedEventConnector{} = selected {PluginPreparation.events = map eventMethod selected.events}
    connector selected = selected
    eventMethod (PreparedEvent name label interval input reply cursor poll dispatch) =
      PreparedEvent name label interval input reply cursor poll (fmap (\(entry,_) -> (entry,safety)) dispatch)

syntheticDispatch :: (FlowStore :> es, Failure :> es, IOE :> es)
  => String -> Instance.FlowInstanceId -> Eff (PluginEvent : es) a -> Eff es a
syntheticDispatch fault identity = interpret $ \_ -> \case
  DispatchEvent _ _ waitIdentity payload -> do
    current <- readInstance identity >>= maybe (error "Missing dispatch instance") pure
    selected <- case current.waits of [value] -> pure value; _ -> error "Missing dispatch wait"
    liftIO $ unless (waitIdentity == Instance.flowInstanceIdText identity <> ":" <> selected.waitId && payload == String "Question")
      (fail "Dispatch changed stable identity or request")
    case fault of
      "forbidden" -> error "Unexpected adapter invocation"
      "fetch" -> pure (Left [errorDiagnostic "flow.dispatch-failed" "provider rejected request"])
      "operational" -> raiseFailure (Failure.RuntimeUnavailable (Failure.ProcessDiagnostic Failure.ReadOutput "injected failure"))
      "cursor" -> pure (Right (String "invalid cursor"))
      "cancel" -> cancelInstance identity Instance.ThisFlow >> pure (Right (String "10"))
      "manual" -> do
        _ <- queueDelivery identity "during-dispatch" selected.waitId (Instance.ReceivedFrom (Instance.ManualReply "cli")) (String "Answer")
        _ <- resolveDelivery identity "during-dispatch" Instance.Accepted
        pure (Right (String "10"))
      _ -> pure (Right (String "10"))
  PollEvent _ _ waitIdentity payload cursor -> do
    current <- readInstance identity >>= maybe (error "Missing poll instance") pure
    selected <- case current.waits of [value] -> pure value; _ -> error "Missing poll wait"
    liftIO $ unless (waitIdentity == Instance.flowInstanceIdText identity <> ":" <> selected.waitId && payload == String "Question"
      && cursor == (selected.adapter >>= (.cursor))) (fail "Poll changed identity, request or cursor")
    liftIO $ unless (case selected.adapter of
      Just adapter -> adapter.polling.lastAttempt /= Nothing && adapter.polling.nextAttempt /= Nothing
      _ -> False) (fail "Poll invoked before attempt was persisted")
    let arrival value = (EventIdentity "same-event",value)
        batch = ([arrival (String "Answer")],String "11")
    case fault of
      "forbidden" -> error "Unexpected poll invocation"
      "poll-empty" -> pure (Right ([],String "11"))
      "poll-fail" -> pure (Left [errorDiagnostic "fixture.poll" "failed"])
      "poll-operational" -> raiseFailure (Failure.RuntimeUnavailable (Failure.ProcessDiagnostic Failure.ReadOutput "poll failure"))
      "poll-bad" -> pure (Right ([arrival (String "Answer"),(EventIdentity "invalid",Number 7)],String "11"))
      "poll-cursor" -> pure (Right ([arrival (String "Answer")],String "invalid"))
      "poll-conflicts" -> pure (Right (map arrival [String "Answer",String "Changed",String "Answer"],String "11"))
      "poll-cancel" -> cancelInstance identity Instance.ThisFlow >> pure (Right batch)
      "poll-manual" -> do
        _ <- queueDelivery identity "during-poll" selected.waitId (Instance.ReceivedFrom (Instance.ManualReply "cli")) (String "Manual")
        _ <- resolveDelivery identity "during-poll" Instance.Accepted
        pure (Right batch)
      _ -> pure (Right batch)

fixtureTime :: UTCTime
fixtureTime = read "2026-11-24 12:00:00 UTC"
fixedClock :: UTCTime -> Eff (Clock : es) a -> Eff es a
fixedClock time = interpret $ \_ CurrentTime -> pure time

shortDeadlines :: (Deadline :> es, IOE :> es) => Eff es a -> Eff es a
shortDeadlines = interpose $ \env (WithinMicroseconds duration action) -> do
  liftIO $ unless (duration == 60000000) (fail "Event adapter did not use the fixed host-wide policy")
  localSeqUnlift env $ \unlift -> withinMicroseconds 1000000 (unlift action)

rerouteGuest :: GuestExecution :> es => Instance.FlowInstanceId -> FilePath -> Eff es a -> Eff es a
rerouteGuest identity replacement = interpose $ \env operation -> case operation of
  ExecuteCompiled program input -> executeCompiled program input
  ExecuteGuest program@(CompiledProgram build _ retention) input respond -> localSeqUnlift env $ \unlift ->
    executeGuest (if TextEncoding.encodeUtf8 (Instance.flowInstanceIdText identity <> ":") `Bytes.isInfixOf` input.metadata
      then CompiledProgram build replacement retention else program) input (unlift . respond)
