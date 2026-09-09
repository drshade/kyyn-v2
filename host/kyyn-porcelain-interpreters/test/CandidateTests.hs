{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module CandidateTests (candidateTests) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value(..), object, (.=))
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Data.Text (pack)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.List (isInfixOf)
import Effectful (Eff, IOE, (:>), runEff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret, send)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Evolution
import Kyyn.Domain.EvolutionReport
import Kyyn.Domain.Failure (OperationalFailure(..), StorageDiagnostic(..), StorageOperation(ReplaceFile))
import Kyyn.Domain.FileTree
import Kyyn.Domain.Git
import Kyyn.Domain.KnowledgeBase
import Kyyn.Domain.Path
import Kyyn.Domain.Root
import Kyyn.Domain.Workspace
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..))
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Types.SchemaMetadata
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Plumbing.Capability.FileSystem (FileSystem(..))
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Protocol.EvolutionRecord (encodeEvolutionRecord, decodeEvolutionRecord)
import Kyyn.Plumbing.Protocol.EvolutionRecord.Contract (snapshotShape, snapshotValue, restoreSnapshot)
import Kyyn.Porcelain.Capability.Evolution (applyEvolution, checkEvolution)
import Kyyn.Porcelain.Capability.EvolutionAuthoring (EvolutionAuthoring(..))
import Kyyn.Porcelain.Capability.EvolutionExecution (EvolutionExecution(..))
import Kyyn.Porcelain.Capability.EvolutionStore
import Kyyn.Porcelain.Capability.RootExecution (RootExecution(..), preparedRoot)
import Kyyn.Porcelain.RootExecution.Types (PreparedRoot(..))
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.Capability.Validation (checkCandidate)
import Kyyn.Porcelain.Capability.WorkspaceStore (WorkspaceStore, readWorkspaceSnapshot)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Porcelain.Validated (validatedValue)
import System.Directory (listDirectory, removeFile, createDirectoryIfMissing, doesDirectoryExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

type StoreEffects = '[EvolutionStore, Git.Git, WorkspaceStore, RootStore, DhallHandling, FileSystem, Failure, IOE]

candidateTests :: RootContract -> FileTree -> IO ()
candidateTests schema facts = withSystemTempDirectory "kyyn-candidates" $ \directory -> do
  contractDescriptions schema
  scope <- right (directoryScope directory)
  revision <- right (gitRevision (replicate 40 'a'))
  identity <- right (evolutionId "e001")
  prefix <- Subtree <$> right (relativePath "nested/kb")
  empty <- right (fileTree [])
  code <- right (fileTree [(either error id (relativePath "src/Schema.hs"), "captured source λ")])
  beforeFiles <- right (fileTree [(either error id (relativePath "Before.hs"),"captured Before")])
  changeFiles <- right (fileTree [(either error id (relativePath "Evolution.hs"),"captured entry")])
  capturedNotes <- right (fileTree [(either error id (relativePath "old.md"),"old review note")])
  let kb = KnowledgeBase (Repository scope) prefix
      location = EvolutionWorkspace kb identity
      snapshot = WorkspaceSnapshot (WorkspaceManifest revision "Review λ" "Explain this" Draft) beforeFiles code changeFiles capturedNotes
      context = EvolutionContext kb identity (Before revision schema) snapshot
      captured = CapturedEvolution context (Root schema facts code) []
      factValue = object ["id" .= ("a" :: String), "value" .= object ["title" .= ("one" :: String)]]
      previousValue = object ["id" .= ("a" :: String), "value" .= object ["title" .= ("previous" :: String)]]
      report = EvolutionReport
        [StepReport (Rationale "Keep rationale λ" [EvidenceRef "graph" "mail" "inbox" ["https://example.test/mail/1"]])
          [FactChange "todos" (FactId "a") (Just (RecordedFact schema previousValue)) (Just (RecordedFact schema factValue))],
         StepReport (Rationale "No fact changes" []) []]
      root = Root schema facts code
      candidate = Candidate context report root
      execute :: Eff StoreEffects a -> IO (Either OperationalFailure a)
      execute = runEff . runFailure . runFileSystemIO scope . runDhallHandling . runRootStore
        . runWorkspaceStore . noGit . runEvolutionStore
      candidateDir = directory </> "nested/kb/.kyyn/candidates"
      cache = directory </> "nested/kb/.kyyn"
      ignoreFile = cache </> ".gitignore"
      pointer = candidateDir </> "latest/e001"
  unless (fmap id candidate == candidate && fmap (const ()) candidate == Candidate context report ())
    (fail "Candidate mapping changed context/report")
  absent <- execute (loadCandidate location)
  unless (absent == Right (Right Nothing)) (fail "Absent selection did not return Nothing")
  cacheExists <- doesDirectoryExist cache
  unless (not cacheExists) (fail "Reading an absent candidate created its cache")
  execute (saveCandidate candidate) >>= right
  ignoreRule <- Bytes.readFile ignoreFile
  unless (ignoreRule == "*\n") (fail "Cache is not self-ignoring")
  Bytes.writeFile ignoreFile "*\n# Preserve authored cache ignore rules\n"
  first <- Char8.readFile pointer
  loaded <- execute (loadCandidate location) >>= right >>= right
  unless (loaded == Just candidate) (fail "Candidate round trip changed context, root or report")
  let latestPath = candidateDir </> Char8.unpack first
      metadataPath = latestPath </> "candidate.dhall"
  metadata <- Bytes.readFile metadataPath
  let capturedManifest = latestPath </> "capture/manifest.dhall"
  currentManifest <- Bytes.readFile capturedManifest
  Bytes.writeFile capturedManifest ("(" <> currentManifest <> ") // { extra = [] : List Text }")
  execute (loadCandidate location) >>= \case
    Right (Left [Diagnostic Error "candidate.stale" _ _]) -> pure ()
    other -> fail ("Outdated captured workspace was not classified as stale: " ++ show other)
  Bytes.writeFile capturedManifest currentManifest
  let futureRecord = "(" <> metadata <> ") // { version = +2 }"
  case runPureEff (runDhallHandling (decodeEvolutionRecord futureRecord)) of
    Right (Left [Diagnostic Error "evolution.record-format" message _])
      | not ("apply" `isInfixOf` message) -> pure ()
    other -> fail ("Unsupported archive format was corruption or requested replay: " ++ show other)
  case runPureEff (runDhallHandling (decodeEvolutionRecord "{ version = +2, content = True }")) of
    Right (Left [Diagnostic Error "evolution.record-format" _ _]) -> pure ()
    other -> fail ("Unsupported version required the current schema: " ++ show other)
  Bytes.writeFile metadataPath futureRecord
  execute (loadCandidate location) >>= \case
    Right (Left [Diagnostic Error "candidate.stale" _ _]) -> pure ()
    other -> fail ("Unsupported private result did not request reapplication: " ++ show other)
  Bytes.writeFile metadataPath metadata
  let fingerprint = pack (contractFingerprint (contractId (rootSchema schema)))
      replace from to = Text.encodeUtf8 (Text.replace from to (Text.decodeUtf8 metadata))
  Bytes.writeFile metadataPath (replace fingerprint "different-contract")
  execute (loadCandidate location) >>= \case
    Right (Left (Diagnostic Error "candidate.stale" _ _ : _)) -> pure ()
    other -> fail ("Changed contract did not report staleness: " ++ show other)
  Bytes.writeFile metadataPath "{"
  execute (loadCandidate location) >>= storageRejected
  Bytes.writeFile metadataPath (replace "\"one\"" "True")
  execute (loadCandidate location) >>= storageRejected
  Bytes.writeFile metadataPath metadata
  (missingPath, missingBytes) <- case files facts of
    entry : _ -> pure entry
    [] -> fail "Fixture has no fact files"
  let factPath = latestPath </> "root" </> relativeName missingPath
  removeFile factPath
  execute (loadCandidate location) >>= storageRejected
  Bytes.writeFile factPath missingBytes
  value <- runEff . runDhallHandling . runRootStore $ loadRootValueForChecking root
  checked <- right value
  let migrationType = case rootType (rootSchema schema) of
        Algebraic _ args [Constructor _ fields] -> Algebraic "Migrated.Root" args
          [Constructor "Migrated.Root" (fields ++ [(Just "confirmed",BoolType)])]
        _ -> error "Expected record root fixture"
  migratedSchema <- right (checkContract migrationType (metadataOf (rootSchema schema)) >>= checkRootLayout)
  migratedId <- right (evolutionId "e002")
  migratedCode <- right (fileTree [(either error id (relativePath "src/Migrated.hs"),"new schema source")])
  let migratedValue = case checked of
        CheckedValue _ (Object values) -> Object (KeyMap.insert "confirmed" (Bool True) values)
        _ -> error "Expected record root value"
      migratedSnapshot = WorkspaceSnapshot (WorkspaceManifest revision "Migration" "Add confirmation" Draft) empty migratedCode empty empty
      migratedContext = EvolutionContext kb migratedId (Before revision schema) migratedSnapshot
      migratedCapture = CapturedEvolution migratedContext (Root schema facts code) []
      migratedReport = EvolutionReport [StepReport (Rationale "New schema" [])
        [FactChange "todos" (FactId "a") (Just (RecordedFact schema factValue)) (Just (RecordedFact migratedSchema factValue))]]
  migratedChecked <- runEff . runDhallHandling . runRootStore $ checkRootValue migratedSchema migratedValue
  migratedInput <- right migratedChecked
  migrated <- execute (evaluationMock migratedCapture
    (Right (EvaluatedEvolution migratedCapture (After migratedSchema) migratedInput migratedReport))
    (applyEvolution migratedCapture)) >>= right >>= right
  migratedLoaded <- execute (loadCandidate (EvolutionWorkspace kb migratedId)) >>= right >>= right
  unless (migratedLoaded == Just migrated) (fail "Schema-changing candidate lost Before/After or recorded contracts")
  let evaluated = EvaluatedEvolution captured (After schema) checked report
  applied <- execute (evaluationMock captured (Right evaluated) (applyEvolution captured)) >>= right >>= right
  unless (applied == candidate) (fail "Application changed the evaluated context/value/report")
  selected <- execute (loadCandidate location) >>= right >>= right
  unless (selected == Just applied) (fail "Application returned before saving its candidate")
  second <- Char8.readFile pointer
  unless (first /= second) (fail "Save reused a mutable result directory")
  preservedIgnore <- Bytes.readFile ignoreFile
  unless (preservedIgnore == "*\n# Preserve authored cache ignore rules\n") (fail "Saving rewrote an existing cache ignore rule")
  originalMetadata <- Bytes.readFile metadataPath
  unless (originalMetadata == metadata && loaded == Just candidate) (fail "Second save mutated the previous result")
  let rejection = ProposedCodeRejected [errorDiagnostic "test.rejected" "Do not save"]
  refused <- execute (evaluationMock captured (Left rejection) (applyEvolution captured))
  unless (refused == Right (Left rejection)) (fail "Application lost evaluation rejection")
  afterRejection <- Char8.readFile pointer
  unless (afterRejection == second) (fail "Rejected evaluation replaced the last successful result")
  let malformed = EvaluatedEvolution captured (After schema) (CheckedValue (contractId (rootSchema schema)) Null) report
  execute (evaluationMock captured (Right malformed) (applyEvolution captured)) >>= \case
    Right (Left (ProposedCodeRejected _)) -> pure ()
    other -> fail ("Invalid materialization returned a candidate: " ++ show other)
  let failure = StorageUnavailable (StorageDiagnostic ReplaceFile "latest/e001" "Cannot publish")
  failed <- runEff . runFailure . runFileSystemIO scope . failPublication failure . runDhallHandling
    . runRootStore . runWorkspaceStore . noGit . runEvolutionStore $
      evaluationMock captured (Right evaluated) (applyEvolution captured)
  unless (failed == Left failure) (fail "Failed save returned a successful candidate")
  afterFailure <- Char8.readFile pointer
  unless (afterFailure == second) (fail "Failed publication replaced the previous result")
  let warning = Diagnostic Warning "test.warning" "Review this" Nothing
  validation <- runEff . runDhallHandling . runRootStore . validationMock root (ValidationReport [warning]) $ checkCandidate candidate
  case validation of
    Passed checkedCandidate (ValidationReport ds) -> do
      unless (fmap validatedValue checkedCandidate == candidate && ds == [warning])
        (fail "Candidate checking changed context/report or lost warnings")
      (_,absentNotesExport) <- execute (exportAcceptedWorkspace checkedCandidate) >>= right >>= right
      unless (all (\(p,_) -> take 6 (relativeName p) /= "notes/") (files absentNotesExport))
        (fail "Absent live notes resurrected captured review notes")
      let liveWorkspace = directory </> "nested/kb/evolutions/e001"
          noteBytes = "subject: original evaluated result\nKeep this later note unchanged"
      createDirectoryIfMissing True (liveWorkspace </> "notes")
      createDirectoryIfMissing True (liveWorkspace </> "target/src")
      Bytes.writeFile (liveWorkspace </> "notes/new.md") noteBytes
      Bytes.writeFile (liveWorkspace </> "manifest.dhall") "invalid live manifest"
      Bytes.writeFile (liveWorkspace </> "target/src/Schema.hs") "edited source, not captured"
      (archivePrefix,exported) <- execute (exportAcceptedWorkspace checkedCandidate) >>= right >>= right
      expectedPrefix <- Subtree <$> right (relativePath "nested/kb/evolutions/e001")
      unless (archivePrefix == expectedPrefix) (fail "Archive export escaped its KB/workspace prefix")
      let entries = [(relativeName p,b) | (p,b) <- files exported]
      recordBytes <- maybe (fail "Missing archive record") pure (lookup "result.dhall" entries)
      decoded <- right (runPureEff (runDhallHandling (decodeEvolutionRecord recordBytes))) >>= right
      unless (decoded == (identity,schema,schema,report)) (fail "Archive changed contract identities, step report or rationale")
      workspaceFiles <- right (fileTree [(p,b) | (p,b) <- files exported, relativeName p /= "result.dhall"])
      archived <- runEff . runDhallHandling . runWorkspaceStore $ readWorkspaceSnapshot workspaceFiles
      currentNotes <- right (fileTree [(either error id (relativePath "new.md"),noteBytes)])
      unless (archived == Right (WorkspaceSnapshot
          (WorkspaceManifest revision "Review λ" "Explain this" Accepted) beforeFiles code changeFiles currentNotes))
        (fail "Archive substituted live source/manifest or failed to preserve current notes/deletions")
      liveManifest <- Bytes.readFile (liveWorkspace </> "manifest.dhall")
      unless (liveManifest == "invalid live manifest") (fail "Export modified the live lifecycle state")
      removeFile (liveWorkspace </> "notes/new.md")
      (_,withoutNotes) <- execute (exportAcceptedWorkspace checkedCandidate) >>= right >>= right
      unless (all (\(p,_) -> take 6 (relativeName p) /= "notes/") (files withoutNotes))
        (fail "Export resurrected captured notes after deletion")
      let Candidate _ _ checkedRoot = checkedCandidate
          wrongContext = EvolutionContext kb identity (Before revision schema)
            (WorkspaceSnapshot (WorkspaceManifest revision "Review λ" "Explain this" Draft) beforeFiles empty changeFiles capturedNotes)
      execute (exportAcceptedWorkspace (Candidate wrongContext report checkedRoot)) >>= right >>= \case
        Left [Diagnostic Error "evolution.archive-context" _ _] -> pure ()
        _ -> fail "Archive accepted code differing from the checked root"
    other -> fail (show other)
  let invalid = errorDiagnostic "test.invalid" "Invalid root"
  invalidResult <- runEff . runDhallHandling . runRootStore . validationMock root (ValidationReport [invalid]) $ checkCandidate candidate
  unless (invalidResult == Rejected (ValidationReport [invalid])) (fail "Invalid candidate earned validation")
  let compileError = [errorDiagnostic "test.compile" "Broken validator"]
      compileRejected = interpret (\_ -> \case
        PrepareRoot selectedRoot | selectedRoot == root -> pure (Left compileError)
        _ -> error "Compile-rejected candidate ran checking")
  compileResult <- runEff . runDhallHandling . runRootStore . compileRejected $ checkCandidate candidate
  unless (compileResult == Rejected (ValidationReport compileError)) (fail "Compile error did not reject candidate checking")
  previousPointer <- Char8.readFile pointer
  combined <- execute . captureMock location captured . evaluationMock captured (Right evaluated)
    . validationMock root (ValidationReport [invalid]) $ checkEvolution location
  unless (combined == Right (Right (Rejected (ValidationReport [invalid]))))
    (fail "Combined check lost semantic rejection")
  invalidPointer <- Char8.readFile pointer
  unless (invalidPointer /= previousPointer) (fail "Combined check did not save its rejected candidate")
  retained <- execute (loadCandidate location) >>= right >>= right
  unless (retained == Just candidate) (fail "Rejected candidate was unavailable for inspection")
  preparation <- execute . captureMock location captured . evaluationMock captured (Left rejection)
    . validationMock root (error "Preparation refusal reached validation") $ checkEvolution location
  unless (preparation == Right (Left rejection)) (fail "Combined check lost preparation refusal")
  unchangedPointer <- Char8.readFile pointer
  unless (unchangedPointer == invalidPointer) (fail "Preparation refusal replaced the previous candidate")
  passed <- execute . captureMock location captured . evaluationMock captured (Right evaluated)
    . validationMock root (ValidationReport [warning]) $ checkEvolution location
  case passed of
    Right (Right (Passed result (ValidationReport ds))) ->
      unless (fmap validatedValue result == candidate && ds == [warning]) (fail "Combined check lost candidate or warnings")
    other -> fail (show other)
  forM_ ["../outside", "missing", ""] $ \bad -> do
    Char8.writeFile pointer bad
    execute (loadCandidate location) >>= storageRejected
  Char8.writeFile pointer "deadbeef"
  execute (loadCandidate location) >>= storageRejected
  entries <- listDirectory candidateDir
  unless (length entries >= 3) (fail "Completed private directories were not retained")
  putStrLn "Candidate persistence, immutable reload, stale contracts, publication failure, application and checking passed."

contractDescriptions :: RootContract -> IO ()
contractDescriptions baseline = do
  let status = Algebraic "Saved.Status" [] [Constructor "Saved.Open" [], Constructor "Saved.Done" []]
      payload = Algebraic "Saved.Payload" [StringType]
        [Constructor "Saved.Named" [(Just "label",StringType)], Constructor "Saved.Number" [(Nothing,IntegerType)]]
      todo = Algebraic "Saved.Todo" [] [Constructor "Saved.Todo"
        [(Just "title",StringType), (Just "status",status), (Just "parent",OptionalType sdkFactIdType)]]
      fact = Algebraic "Kyyn.Types.Fact.Fact" [todo]
        [Constructor "Kyyn.Types.Fact.Fact" [(Nothing,sdkFactIdType),(Nothing,todo)]]
      rootType' = Algebraic "Saved.Root" [] [Constructor "Saved.Root"
        [(Just "todos",ListType fact),(Just "count",IntegerType),(Just "enabled",BoolType),
         (Just "optional",OptionalType StringType),(Just "payloads",ListType payload)]]
      metadata = SchemaMetadata
        [RoleDecl "name" "Readable name" Title, RoleDecl "badge" "Status" Badge, RoleDecl "time" "Unused timeline" Timeline]
        [FieldRole "Saved.Todo" "title" "name", FieldRole "Saved.Todo" "status" "badge"]
        [CollectionDecl "todos" "todos" [("parent","todos")]]
  schema <- right (checkContract rootType' metadata >>= checkRootLayout)
  identity <- right (evolutionId "e003")
  let envelope contents = object ["id" .= ("a" :: String),"value" .= contents]
      old = RecordedFact baseline (envelope (object ["title" .= ("Before" :: String)]))
      changed = RecordedFact baseline (envelope (object ["title" .= ("Edited" :: String)]))
      new = RecordedFact schema (envelope (object ["title" .= ("München 🌍" :: String),
        "status" .= object ["tag" .= ("Done" :: String)],
        "parent" .= object ["tag" .= ("Some" :: String), "value" .= ("b" :: String)]]))
      step description before after = StepReport (Rationale description [])
        [FactChange "todos" (FactId "a") before after]
      report = EvolutionReport [step "Edit" (Just old) (Just changed),
        step "Migrate" (Just changed) (Just new), step "Delete" (Just new) Nothing,
        step "Add" Nothing (Just new), StepReport (Rationale "No change" []) []]
  encoded <- right (runPureEff (runDhallHandling (encodeEvolutionRecord identity baseline schema report)))
  decodedReport <- right (runPureEff (runDhallHandling (decodeEvolutionRecord encoded))) >>= right
  unless (decodedReport == (identity,baseline,schema,report))
    (fail "Dhall record changed migration steps, typed payloads or optional fact sides")
  forM_ [baseline,schema] $ \selected -> do
    restored <- right (restoreRootContract (describeRootContract selected)) >>= right
    unless (restored == selected) (fail "Contract descriptions changed types, metadata, layout or fingerprint")
    source <- right (runPureEff (runDhallHandling (encodeValue snapshotShape (snapshotValue selected))))
    document <- right (runPureEff (runDhallHandling (decodeValue snapshotShape source)))
    decoded <- right (parseEither restoreSnapshot document) >>= right
    unless (decoded == selected) (fail "Dhall snapshot changed types, metadata, layout or fingerprint")
  forM_ ["-1","0","1","999999999999999999999999999999999999999999"] $ \index -> do
    let malformed = object ["fingerprint" .= ("unused" :: String), "types" .=
          [object ["tag" .= ("List" :: String), "value" .= (index :: String)]], "metadata" .= object []]
    case parseEither restoreSnapshot malformed of
      Left _ -> pure ()
      other -> fail ("Forward, cyclic or out-of-range type reference accepted: " ++ show other)
  case restoreRootContract Null of
    Left _ -> pure ()
    other -> fail ("Malformed contract description accepted: " ++ show other)

noGit :: Eff (Git.Git : es) a -> Eff es a
noGit = interpret $ \_ _ -> error "Candidate operation read Git"

captureMock :: EvolutionWorkspace -> CapturedEvolution -> Eff (EvolutionAuthoring : es) a -> Eff es a
captureMock expected captured = interpret $ \_ -> \case
  CaptureEvolution actual | actual == expected -> pure (Right captured)
  _ -> error "Combined check selected a different workspace or created one"

evaluationMock :: CapturedEvolution -> Either PreviewRejection EvaluatedEvolution
  -> Eff (EvolutionExecution : es) a -> Eff es a
evaluationMock expected answer = interpret $ \_ -> \case
  EvaluateEvolution captured -> if captured == expected then pure answer else error "Evaluated different inputs"

failPublication :: (FileSystem :> es, Failure :> es) => OperationalFailure -> Eff (FileSystem : es) a -> Eff es a
failPublication failure = interpret $ \_ -> \case
  ReplaceBytes {} -> raiseFailure failure
  WithTemporaryScope {} -> error "Candidate persistence requested a temporary scope"
  ReadBytes scope path -> send (ReadBytes scope path)
  ReadOptionalBytes scope path -> send (ReadOptionalBytes scope path)
  WriteBytes scope path bytes -> send (WriteBytes scope path bytes)
  ReadTree scope -> send (ReadTree scope)
  ListDirectory scope -> send (ListDirectory scope)
  CreateUniqueDirectory scope -> send (CreateUniqueDirectory scope)
  CreateDirectory {} -> error "Candidate persistence must not reserve named directories"
  EnsureDirectory {} -> error "Candidate persistence must not initialize directories"
  EntryExists {} -> error "Candidate persistence must not inspect entries"

validationMock :: Root -> ValidationReport -> Eff (RootExecution : es) a -> Eff es a
validationMock expected report = interpret $ \_ -> \case
  PrepareRoot root | root == expected -> pure (Right (PreparedRoot root "validator" (error "Unexpected bytecode use") []))
  ValidateRoot root | preparedRoot root == expected -> pure (Right report)
  _ -> error "Candidate checking changed roots or executed a query"

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

storageRejected :: Show a => Either OperationalFailure a -> IO ()
storageRejected (Left (StorageUnavailable _)) = pure ()
storageRejected other = fail ("Expected storage failure: " ++ show other)
