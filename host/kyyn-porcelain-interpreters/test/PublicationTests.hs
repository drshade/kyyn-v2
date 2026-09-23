{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings, TypeApplications #-}
module PublicationTests (publicationTests) where

import Control.Exception (AsyncException(..), throwIO, try)
import Kyyn.Domain.Curation (emptyCurationRegister)
import Control.Monad (unless, when, forM_)
import Data.Aeson (Value, object, (.=))
import Data.Coerce (coerce)
import Data.IORef (newIORef, atomicModifyIORef')
import qualified Data.ByteString as Bytes
import Effectful (Eff, IOE, (:>), runEff, runPureEff, liftIO)
import Effectful.Dispatch.Dynamic (interpret, send)
import Kyyn.Domain.Contract
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Evolution
import Kyyn.Domain.EvolutionReport
import Kyyn.Domain.FileTree
import Kyyn.Domain.Git
import Kyyn.Domain.KnowledgeBase
import Kyyn.Domain.Path
import Kyyn.Domain.Publication
import Kyyn.Domain.Root
import Kyyn.Domain.Workspace
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import qualified Kyyn.Plumbing.Capability.FileSystem as FileSystem
import qualified Kyyn.Plumbing.Capability.Git as Git
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process
import qualified Kyyn.Plumbing.Capability.SchemaInspection as Schema
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Git (runGit)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Plumbing.Protocol.EvolutionRecord (decodeEvolutionRecord)
import Kyyn.Porcelain.Capability.Evolution (applyEvolution, acceptStoredEvolution)
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore)
import Kyyn.Porcelain.Capability.EvolutionExecution
import Kyyn.Porcelain.Capability.EvolutionReport (checkEvolutionReport)
import Kyyn.Porcelain.Capability.EvolutionStore
import Kyyn.Porcelain.Capability.EvolutionAuthoring
import Kyyn.Porcelain.Capability.RootExecution
import Kyyn.Porcelain.RootExecution.Types (PreparedRoot(..))
import Kyyn.Porcelain.Capability.RootOpening
import Kyyn.Porcelain.Capability.RootPublication
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.Capability.Validation (checkCandidate)
import Kyyn.Porcelain.Capability.WorkspaceStore
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.EvolutionAuthoring (runEvolutionAuthoring)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.RootPublication (runRootPublication)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Porcelain.Validated (Validated, validatedValue)
import System.Directory (createDirectoryIfMissing, findExecutable, removeFile, doesPathExist)
import System.FilePath ((</>), takeDirectory)
import System.IO.Temp (withSystemTempDirectory)

type Effects = '[EvidenceStore, RootPublication, RootExecution, EvolutionExecution, EvolutionAuthoring, EvolutionStore,
  RootOpening, Schema.SchemaInspection, WorkspaceStore, RootStore, DhallHandling,
  Git.Git, Git.Git, Process.ProcessExecution, FileSystem, Failure, IOE]

publicationTests :: Root -> IO ()
publicationTests (Root contract facts _ _) = forM_ [False, True] $ \interrupt ->
  withSystemTempDirectory "kyyn-publication" $ \directory -> do
    executable <- findExecutable "git" >>= maybe (fail "Git required") pure
    scope <- either fail pure (directoryScope directory)
    let repo = Repository scope
        path = either error id . relativePath
        tree = either error id . fileTree
        prefix = if interrupt then Subtree (path "nested/kb") else WholeTree
        kb = KnowledgeBase repo prefix
        kbPath name = either error relativeName (relativePath name >>= knowledgeBasePath kb)
        rootPath = either error id (rootLocation kb)
        manifest = "{ schemaType = \"Example.Root\", schemaMetadata = \"Example.schemaMetadata\", validator = \"Example.validate\", queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, recipes = [] : List { name : Text, instructions : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }"
        pluginFile = "plugins/packages/existing/source/src/Plugin.hs"
        pluginBytes = "module Plugin where\n"
        code = tree [(path "kb.dhall",manifest), (path "src/Schema.hs","authored source"),
          (path pluginFile,pluginBytes)]
        initialRoot = Root contract facts code emptyCurationRegister
        output = object ["description" .= ("accepted" :: String), "todos" .= ([] :: [Value])]
        write name bytes = do
          createDirectoryIfMissing True (takeDirectory (directory </> name))
          Bytes.writeFile (directory </> name) bytes
        writeTreeAt location entries = forM_ (files entries) $ \(p,b) -> write (location ++ "/" ++ relativeName p) b
        inspect args = do
          result <- runEff . runFailure . runProcessExecutionIO $ Process.withProcess
            (Process.ProcessSpec executable args directory [("PATH",""),("LC_ALL","C")]) $ do
              Process.closeStdin
              bytes <- Process.collectStdout
              status <- Process.awaitExit
              pure (bytes,status)
          case result of Right (bytes,Process.ProcessExit 0 _) -> pure bytes; _ -> fail (show result)
        command args = () <$ inspect args
        metadata = CommitMetadata
          (CommitIdentity "Author" "author@example.invalid" "1700000000 +0000")
          (CommitIdentity "Committer" "committer@example.invalid" "1700000001 +0000") "Accept fixture\n"
        branch = LocalBranch "main"
        run :: Bool -> Maybe Bool -> (String -> IO ()) -> Eff Effects a -> IO a
        run opening validation hook action = do
          result <- runEff . runFailure . runFileSystemIO scope . runProcessExecutionIO
            . runGit executable [] . gitHook hook . runDhallHandling . runRootStore
            . runWorkspaceStore . schemaMock contract
            . (if opening then runRootOpening (tree []) else noOpening)
            . runEvolutionStore . runEvolutionAuthoring . evaluationMock output . validationMock validation
            . runRootPublication . noEvidence $ action
          either (fail . show) pure result
        normal :: Eff Effects a -> IO a
        normal = run True (Just True) (const (pure ()))
        publication :: Eff Effects a -> IO a
        publication = run False Nothing (const (pure ()))
        assert label condition = unless condition (fail label)
        headRevision = publication (Git.resolveRevision repo "HEAD") >>= right
    command ["init", "-q", "--ref-format=files", "-b", "main"]
    writeTreeAt (relativeName rootPath) (tree (files facts ++ files code))
    write "outside" "committed outside"
    command ["add", relativeName rootPath, "outside"]
    command ["-c","user.name=Fixture","-c","user.email=fixture@example.invalid",
      "-c","commit.gpgsign=false","commit","-qm","initial root"]
    base <- headRevision
    workspace@(EvolutionWorkspace _ identity) <- normal (createEvolution kb (EvolutionName "First") base) >>= right
    other <- normal (createEvolution kb (EvolutionName "Other") base) >>= right
    workspacePath <- either fail (pure . relativeName) (workspaceLocation workspace)
    otherPath <- either fail (pure . relativeName) (workspaceLocation other)
    inheritedPlugin <- Bytes.readFile (directory </> workspacePath </> "target" </> pluginFile)
    assert "New evolution omitted accepted plugin source" (inheritedPlugin == pluginBytes)
    let accept = acceptStoredEvolution branch metadata workspace
        unchanged result expected = do
          assert ("Unexpected refusal: " ++ show result) (result == NotAccepted expected)
          current <- headRevision
          assert "Refusal advanced HEAD" (current == base)
    absent <- publication accept
    case absent of NotAccepted (InvalidMaterial _) -> pure (); _ -> fail "Missing candidate accepted"
    noRecovery <- publication (recoverAcceptedEvolution branch workspace)
    assert "Unaccepted draft has a recovery" (noRecovery == Right Nothing)
    captured <- normal (captureEvolution workspace) >>= right
    candidate@(Candidate context report candidateRoot) <- normal (applyEvolution captured) >>= right
    draftInspection <- normal (inspectEvolution workspace base) >>= right
    assert "Draft inspection lost saved report" (snd draftInspection == Just report)
    checked <- normal (checkCandidate candidate) >>= \case
      Passed value _ -> pure value
      otherResult -> fail (show otherResult)
    draft <- normal accept
    unchanged draft (NotReady Draft)
    normal (markReady workspace) >>= right
    beforeChange <- Bytes.readFile (directory </> workspacePath </> "change/Evolution.hs")
    write (workspacePath ++ "/change/Evolution.hs") "edited after evaluation"
    changed <- publication (acceptEvolution branch metadata checked)
    unchanged changed (WorkspaceChanged identity)
    write (workspacePath ++ "/change/Evolution.hs") beforeChange
    write (relativeName rootPath ++ "/untracked") "raw edit"
    overlapping <- publication (acceptEvolution branch metadata checked)
    unchanged overlapping (OverlappingEdits [path (relativeName rootPath ++ "/untracked")])
    removeFile (directory </> relativeName rootPath </> "untracked")
    command ["update-ref", "--no-deref", "HEAD", revisionName base]
    detached <- publication (acceptEvolution branch metadata checked)
    unchanged detached (CheckoutMismatch branch Nothing)
    recoveryDetached <- publication (recoverAcceptedEvolution branch workspace)
    case recoveryDetached of Left _ -> pure (); _ -> fail "Recovery ignored detached HEAD"
    command ["symbolic-ref", "HEAD", "refs/heads/main"]
    rejectedValidation <- run False (Just False) (const (pure ())) accept
    case rejectedValidation of NotAccepted (InvalidMaterial _) -> pure (); _ -> fail "Invalid candidate accepted"
    current <- headRevision
    assert "Failed validation advanced HEAD" (current == base)
    otherCaptured <- normal (captureEvolution other) >>= right
    otherCandidate <- normal (applyEvolution otherCaptured) >>= right
    normal (markReady other) >>= right
    write "outside" "staged outside"
    command ["add", "outside"]
    staged <- inspect ["rev-parse", ":outside"]
    write "outside" "unstaged outside"
    write "untracked-outside" "keep me"
    exported <- publication (exportRootFiles (case checked of Candidate _ _ value -> value)) >>= right
    archived <- publication (exportAcceptedWorkspace checked) >>= right
    let competing message replacements = publication (Git.createCommit repo (GitTree replacements) (Just base)
          (case metadata of CommitMetadata author committer _ -> CommitMetadata author committer message))
        winAtCreation revision "created" = command ["update-ref", "refs/heads/main", revisionName revision, revisionName base]
        winAtCreation _ _ = pure ()
    unrelatedCommit <- competing "Other work" [(Subtree (path "other-committed"), tree [(path "file","other work")])]
    lost <- run False Nothing (winAtCreation unrelatedCommit) (acceptEvolution branch metadata checked)
    assert "Lost CAS was not diagnosed against actual head" (lost == NotAccepted (BaseMismatch base (Just unrelatedCommit)))
    command ["update-ref", "refs/heads/main", revisionName base, revisionName unrelatedCommit]
    sameWorkspaceCommit <- competing "Another writer accepted this workspace" [(Subtree rootPath,exported),archived]
    sameRace <- run False Nothing (winAtCreation sameWorkspaceCommit) (acceptEvolution branch metadata checked)
    case sameRace of AlreadyAccepted revision _ -> assert "Same-workspace CAS race lost accepting revision" (revision == sameWorkspaceCommit)
                     _ -> fail ("Same-workspace CAS race misdiagnosed: " ++ show sameRace)
    command ["update-ref", "refs/heads/main", revisionName base, revisionName sameWorkspaceCommit]
    forM_ ["head-reading", "head-observed"] $ \event -> do
      fired <- newIORef False
      let concurrentAcceptance name = when (name == event) $ do
            first <- atomicModifyIORef' fired (\old -> (True, not old))
            when first (winAtCreation sameWorkspaceCommit "created")
      earlyRace <- run False Nothing concurrentAcceptance (acceptEvolution branch metadata checked)
      case earlyRace of AlreadyAccepted revision _ -> assert "Early race lost acceptance" (revision == sameWorkspaceCommit)
                        _ -> fail ("Concurrent acceptance misdiagnosed at " ++ event ++ ": " ++ show earlyRace)
      command ["update-ref", "refs/heads/main", revisionName base, revisionName sameWorkspaceCommit]
    command ["branch", "other", revisionName base]
    let switchBranch "created" = command ["symbolic-ref", "HEAD", "refs/heads/other"]
        switchBranch _ = pure ()
    switched <- run False Nothing switchBranch (acceptEvolution branch metadata checked)
    assert "Branch selection was not rechecked before CAS" (switched == NotAccepted (CheckoutMismatch branch (Just (LocalBranch "other"))))
    mainAfterSwitch <- publication (Git.resolveRevision repo "refs/heads/main") >>= right
    assert "Branch switch still published" (mainAfterSwitch == base)
    command ["symbolic-ref", "HEAD", "refs/heads/main"]
    removeFile (directory </> kbPath (".kyyn/candidates/latest/" ++ evolutionIdName identity))
    let hook "published" = if interrupt then throwIO UserInterrupt else write ".git/index.lock" "held"
        hook _ = pure ()
    result <- try @AsyncException (run False Nothing hook (acceptEvolution branch metadata checked))
    accepted <- headRevision
    assert "Acceptance did not advance HEAD" (accepted /= base)
    parents <- publication (Git.readCommitParents repo accepted)
    assert "Acceptance did not preserve Before as its single parent" (parents == Right [base])
    if interrupt then assert "Expected interrupted result" (result == Left UserInterrupt)
      else do
        case result of
          Right (AcceptedCommit revision (WorkingTreeUpdateIncomplete _)) -> assert "Lost accepting revision" (revision == accepted)
          _ -> fail ("Sync failure hid acceptance: " ++ show result)
        removeFile (directory </> ".git/index.lock")
    write (workspacePath ++ "/manifest.dhall") "malformed live manifest"
    already <- publication accept
    acceptedInspection <- publication (inspectEvolution workspace accepted) >>= right
    assert "Accepted inspection required cache or live manifest" (snd acceptedInspection == Just report)
    case already of AlreadyAccepted revision _ -> assert "Wrong accepting revision" (revision == accepted); _ -> fail (show already)
    retried <- publication (acceptEvolution branch metadata checked)
    case retried of AlreadyAccepted revision _ -> assert "Direct retry lost acceptance" (revision == accepted); _ -> fail (show retried)
    recovery <- publication (recoverAcceptedEvolution branch workspace) >>= right
    assert "Recovery did not preserve original acceptance/current HEAD" (recovery == Just (CheckoutRecovery accepted accepted WorkingTreeUpdated))
    repeated <- publication (recoverAcceptedEvolution branch workspace) >>= right
    assert "Recovery is not idempotent" (repeated == recovery)
    reopened <- normal (loadRootAt repo accepted (Subtree rootPath)) >>= right
    preservedPlugin <- Bytes.readFile (directory </> relativeName rootPath </> pluginFile)
    assert "Acceptance removed inherited plugin source" (preservedPlugin == pluginBytes)
    assert "Published root is not the checked candidate" (reopened == candidateRoot && validatedValueRoot checked == candidateRoot)
    archive <- publication (Git.readTreeAt repo accepted (Subtree (path workspacePath))) >>= right
    recordBytes <- maybe (fail "Missing archive report") pure (lookup (path "result.dhall") (files archive))
    record <- either fail pure (runPureEff (runDhallHandling (decodeEvolutionRecord recordBytes))) >>= right
    assert "Archive lost fixed report/contracts" (record == (identity,contract,contract,report))
    forM_ (files facts) $ \(p,_) -> when (relativeName p == "facts/todos/a.dhall") $ do
      exists <- doesPathExist (directory </> relativeName rootPath </> relativeName p)
      assert "Deleted fact remains in checkout" (not exists)
    stagedAfter <- inspect ["rev-parse", ":outside"]
    outside <- Bytes.readFile (directory </> "outside")
    untracked <- Bytes.readFile (directory </> "untracked-outside")
    otherState <- publication (readEvolutionState other) >>= right
    assert "Acceptance/recovery overwrote unrelated local work"
      (stagedAfter == staged && outside == "unstaged outside" && untracked == "keep me" && otherState == Ready)
    otherChecked <- normal (checkCandidate otherCandidate) >>= \case Passed value _ -> pure value; x -> fail (show x)
    rebaseHead <- if interrupt then do
      otherScope <- either fail pure (directoryScope (directory </> otherPath))
      sharedFiles <- publication (FileSystem.readTree otherScope)
      shared <- publication (Git.createCommit repo (GitTree [(Subtree (path otherPath),sharedFiles)]) (Just accepted) metadata)
      advanced <- publication (Git.compareAndSwapRef repo branch (Just accepted) shared)
      assert "Could not share draft" (advanced == RefUpdated)
      publication (Git.synchronizeCheckout repo branch shared [path otherPath]) >>= right
      pure shared
      else pure accepted
    stale <- publication (acceptEvolution branch metadata otherChecked)
    assert "Parallel draft was not stale" (stale == NotAccepted (BaseMismatch base (Just rebaseHead)))
    let EvolutionContext _ _ _ (WorkspaceSnapshot (WorkspaceManifest _ name explanation state) before target change notes) =
          case otherCandidate of Candidate otherContext _ _ -> otherContext
    rebasedFiles <- publication (encodeWorkspaceSnapshot (WorkspaceSnapshot
      (WorkspaceManifest rebaseHead name explanation state) before target change notes)) >>= right
    writeTreeAt otherPath rebasedFiles
    rebasedCapture <- normal (captureEvolution other) >>= right
    _ <- normal (applyEvolution rebasedCapture) >>= right
    normal (markReady other) >>= right
    next <- normal (acceptStoredEvolution branch metadata other)
    later <- case next of AcceptedCommit revision WorkingTreeUpdated -> pure revision; _ -> fail (show next)
    laterArchive <- Bytes.readFile (directory </> otherPath </> "manifest.dhall")
    write (relativeName rootPath ++ "/facts/root.dhall") "broken local root"
    laterRecovery <- publication (recoverAcceptedEvolution branch workspace) >>= right
    assert "Recovery targeted old accepting revision" (laterRecovery == Just (CheckoutRecovery accepted later WorkingTreeUpdated))
    laterArchiveAfter <- Bytes.readFile (directory </> otherPath </> "manifest.dhall")
    assert "Recovery touched another accepted archive" (laterArchive == laterArchiveAfter)
    finalHead <- headRevision
    assert "Recovery moved HEAD" (finalHead == later)
    reverted <- publication (Git.createCommit repo (GitTree [(Subtree (path workspacePath),tree [])]) (Just later) metadata)
    revertedUpdate <- publication (Git.compareAndSwapRef repo branch (Just later) reverted)
    assert "Fixture could not remove acceptance" (revertedUpdate == RefUpdated)
    removedRecovery <- publication (recoverAcceptedEvolution branch workspace)
    assert "Removed archive was still treated as accepted" (removedRecovery == Right Nothing)
    removedAcceptance <- publication accept
    case removedAcceptance of NotAccepted (InvalidMaterial _) -> pure (); _ -> fail "Removed acceptance bypassed absent candidate"
    let WorkspaceSnapshot (WorkspaceManifest _ originalName originalExplanation _)
          originalBefore originalTarget originalChange originalNotes = case context of EvolutionContext _ _ _ snapshot -> snapshot
    reacceptFiles <- publication (encodeWorkspaceSnapshot (WorkspaceSnapshot
      (WorkspaceManifest reverted originalName originalExplanation Ready)
      originalBefore originalTarget originalChange originalNotes)) >>= right
    writeTreeAt workspacePath reacceptFiles
    reacceptCapture <- normal (captureEvolution workspace) >>= right
    _ <- normal (applyEvolution reacceptCapture) >>= right
    reaccepted <- normal accept
    reacceptedRevision <- case reaccepted of AcceptedCommit revision WorkingTreeUpdated -> pure revision; _ -> fail (show reaccepted)
    foundAgain <- publication (findAcceptanceOnBranch branch workspace)
    assert "Reacceptance resolved to the old introduction" (foundAgain == Right (Just reacceptedRevision) && reacceptedRevision /= accepted)
    assert "Fixture initial root unexpectedly equals output" (initialRoot /= candidateRoot)
    assert "Candidate context was substituted" (case context of EvolutionContext _ _ (Before revision _) _ -> revision == base)
    putStrLn ("Full acceptance, rebase and recovery passed (interruption: " ++ show interrupt ++ ").")

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

validatedValueRoot :: Candidate (Validated Root) -> Root
validatedValueRoot (Candidate _ _ value) = validatedValue value

validationMock :: Maybe Bool -> Eff (RootExecution : es) a -> Eff es a
validationMock mode = interpret $ \_ operation -> case mode of
  Nothing -> error "Publication/recovery invoked validation"
  Just valid -> case operation of
    PrepareRoot root -> pure (Right (PreparedRoot root "validator" (error "Unexpected bytecode use") [] []))
    ValidateRoot _ -> pure (Right (ValidationReport (if valid then [] else [errorDiagnostic "test.invalid" "Invalid candidate"])))
    ExecuteQuery {} -> error "Unexpected query"

noOpening :: Eff (RootOpening : es) a -> Eff es a
noOpening = interpret $ \_ _ -> error "Publication/recovery reopened source"

noEvidence :: Eff (EvidenceStore : es) a -> Eff es a
noEvidence = interpret $ \_ _ -> error "Publication/recovery read evidence"

schemaMock :: RootContract -> Eff (Schema.SchemaInspection : es) a -> Eff es a
schemaMock contract = interpret $ \_ -> \case
  Schema.InspectType {} -> error "Unexpected plain type inspection"
  Schema.InspectSchema _ -> pure (Right (Schema.InspectedSchema (rootSchema contract) []))

evaluationMock :: (RootOpening :> es, RootStore :> es) => Value -> Eff (EvolutionExecution : es) a -> Eff es a
evaluationMock output = interpret $ \_ (EvaluateEvolution captured@(CapturedEvolution
    (EvolutionContext _ _ (Before _ contract) _) source _ _)) -> do
  CheckedValue _ input <- loadRootValueForChecking source >>= either (error . show) pure
  let fingerprint = contractFingerprint (contractId (rootSchema contract))
      observation = EvolutionObservation output [StepObservation (Rationale "Clear completed work" [])
        (ObservedRoot fingerprint input) (ObservedRoot fingerprint output)] Nothing
  checked <- checkEvolutionReport contract input contract observation
  pure $ case checked of
    Left diagnostics -> Left (ProposedCodeRejected diagnostics)
    Right (value,report) -> Right (EvaluatedEvolution captured (After contract) value report)

gitHook :: (Git.Git :> es, IOE :> es) => (String -> IO ()) -> Eff (Git.Git : es) a -> Eff es a
gitHook hook = interpret $ \_ operation -> case operation of
  Git.ResolveRevision repository "HEAD" -> do
    liftIO (hook "head-reading")
    result <- Git.resolveRevision repository "HEAD"
    liftIO (hook "head-observed")
    pure result
  Git.CreateCommit {} -> do
    result <- forwardGit operation
    liftIO (hook "created")
    pure result
  Git.CompareAndSwapRef {} -> do
    result <- forwardGit operation
    when (result == RefUpdated) (liftIO (hook "published"))
    pure result
  _ -> forwardGit operation

forwardGit :: forall es m a. Git.Git :> es => Git.Git m a -> Eff es a
forwardGit operation = send (coerce operation :: Git.Git (Eff es) a)
