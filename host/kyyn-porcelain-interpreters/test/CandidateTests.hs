{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module CandidateTests (candidateTests) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value(..), encode, eitherDecodeStrict', object, (.=))
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Lazy as Lazy
import Data.Text (pack)
import Effectful (Eff, IOE, (:>), runEff)
import Effectful.Dispatch.Dynamic (interpret, send)
import Kyyn.Domain.Contract
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
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem(..))
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Porcelain.Capability.Evolution (applyEvolution)
import Kyyn.Porcelain.Capability.EvolutionExecution (EvolutionExecution(..))
import Kyyn.Porcelain.Capability.EvolutionStore
import Kyyn.Porcelain.Capability.RootOpening (RootOpening)
import Kyyn.Porcelain.Capability.RootExecution (RootExecution(..))
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.Capability.Validation (checkCandidate)
import Kyyn.Porcelain.Capability.WorkspaceStore (WorkspaceStore)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Porcelain.Validated (validatedValue)
import System.Directory (listDirectory, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

type StoreEffects = '[EvolutionStore, RootOpening, WorkspaceStore, RootStore, DhallHandling, FileSystem, Failure, IOE]

candidateTests :: RootContract -> FileTree -> IO ()
candidateTests schema facts = withSystemTempDirectory "kyyn-candidates" $ \directory -> do
  scope <- right (directoryScope directory)
  revision <- right (gitRevision (replicate 40 'a'))
  identity <- right (evolutionId "e001")
  prefix <- Subtree <$> right (relativePath "nested/kb")
  empty <- right (fileTree [])
  code <- right (fileTree [(either error id (relativePath "src/Schema.hs"), "captured source λ")])
  let kb = KnowledgeBase (Repository scope) prefix
      location = EvolutionWorkspace kb identity
      snapshot = WorkspaceSnapshot (WorkspaceManifest revision "Review λ" "Explain this" Draft []) empty code empty empty
      context = EvolutionContext kb identity (Before revision schema) snapshot
      captured = CapturedEvolution context
      factValue = object ["id" .= ("a" :: String), "value" .= object ["title" .= ("one" :: String)]]
      report = EvolutionReport
        [StepReport (Rationale "Keep rationale λ" [EvidenceRef "graph" "mail" "inbox" ["https://example.test/mail/1"]])
          [FactChange "todos" (FactId "a") (Just (RecordedFact schema factValue)) (Just (RecordedFact schema factValue))],
         StepReport (Rationale "No fact changes" []) []]
      root = Root schema facts code
      candidate = Candidate context report root
      execute :: Eff StoreEffects a -> IO (Either OperationalFailure a)
      execute = runEff . runFailure . runFileSystemIO scope . runDhallHandling . runRootStore
        . runWorkspaceStore . noOpening . runEvolutionStore
      candidateDir = directory </> "nested/kb/.kyyn/candidates"
      pointer = candidateDir </> "latest/e001"
  unless (fmap id candidate == candidate && fmap (const ()) candidate == Candidate context report ())
    (fail "Candidate mapping changed context/report")
  absent <- execute (loadCandidate location)
  unless (absent == Right (Right Nothing)) (fail "Absent selection did not return Nothing")
  execute (saveCandidate candidate) >>= right
  first <- Char8.readFile pointer
  loaded <- execute (loadCandidate location) >>= right >>= right
  unless (loaded == Just candidate) (fail "Candidate round trip changed context, root or report")
  let latestPath = candidateDir </> Char8.unpack first
      metadataPath = latestPath </> "candidate.json"
  metadata <- Bytes.readFile metadataPath
  document <- right (eitherDecodeStrict' metadata)
  let fingerprint = pack (contractFingerprint (contractId (rootSchema schema)))
      stale (String s) | s == fingerprint = String "different-contract"
      stale (Array xs) = Array (fmap stale xs)
      stale (Object xs) = Object (fmap stale xs)
      stale v = v
  Bytes.writeFile metadataPath (Lazy.toStrict (encode (stale document)))
  execute (loadCandidate location) >>= \case
    Right (Left (Diagnostic Error "candidate.stale" _ _ : _)) -> pure ()
    other -> fail ("Changed contract did not report staleness: " ++ show other)
  Bytes.writeFile metadataPath "not json"
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
  let evaluated = EvaluatedEvolution captured (After schema) checked report
  applied <- execute (evaluationMock captured (Right evaluated) (applyEvolution captured)) >>= right >>= right
  unless (applied == candidate) (fail "Application changed the evaluated context/value/report")
  selected <- execute (loadCandidate location) >>= right >>= right
  unless (selected == Just applied) (fail "Application returned before saving its candidate")
  second <- Char8.readFile pointer
  unless (first /= second) (fail "Save reused a mutable result directory")
  originalMetadata <- Bytes.readFile metadataPath
  unless (originalMetadata == metadata && loaded == Just candidate) (fail "Second save mutated the previous result")
  let rejection = ProposedCodeRejected [errorDiagnostic "test.rejected" "Do not save"]
  refused <- execute (evaluationMock captured (Left rejection) (applyEvolution captured))
  unless (refused == Right (Left rejection)) (fail "Application lost evaluation rejection")
  afterRejection <- Char8.readFile pointer
  unless (afterRejection == second) (fail "Rejected evaluation replaced the last successful result")
  let failure = StorageUnavailable (StorageDiagnostic ReplaceFile "latest/e001" "Cannot publish")
  failed <- runEff . runFailure . runFileSystemIO scope . failPublication failure . runDhallHandling
    . runRootStore . runWorkspaceStore . noOpening . runEvolutionStore $
      evaluationMock captured (Right evaluated) (applyEvolution captured)
  unless (failed == Left failure) (fail "Failed save returned a successful candidate")
  afterFailure <- Char8.readFile pointer
  unless (afterFailure == second) (fail "Failed publication replaced the previous result")
  warning <- pure (Diagnostic Warning "test.warning" "Review this" Nothing)
  validation <- runEff . runDhallHandling . runRootStore . validationMock root (ValidationReport [warning]) $ checkCandidate candidate
  case validation of
    Passed checkedCandidate (ValidationReport ds) ->
      unless (fmap validatedValue checkedCandidate == candidate && ds == [warning])
        (fail "Candidate checking changed context/report or lost warnings")
    other -> fail (show other)
  let invalid = errorDiagnostic "test.invalid" "Invalid root"
  invalidResult <- runEff . runDhallHandling . runRootStore . validationMock root (ValidationReport [invalid]) $ checkCandidate candidate
  unless (invalidResult == Rejected (ValidationReport [invalid])) (fail "Invalid candidate earned validation")
  forM_ ["../outside", "missing", ""] $ \bad -> do
    Char8.writeFile pointer bad
    execute (loadCandidate location) >>= storageRejected
  Char8.writeFile pointer "deadbeef"
  execute (loadCandidate location) >>= storageRejected
  entries <- listDirectory candidateDir
  unless (length entries >= 3) (fail "Completed private directories were not retained")
  putStrLn "Candidate persistence, immutable reload, stale contracts, publication failure, application and checking passed."

noOpening :: Eff (RootOpening : es) a -> Eff es a
noOpening = interpret $ \_ _ -> error "Candidate operation opened or compiled a source root"

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
  CreateUniqueDirectory scope -> send (CreateUniqueDirectory scope)

validationMock :: Root -> ValidationReport -> Eff (RootExecution : es) a -> Eff es a
validationMock expected report = interpret $ \_ -> \case
  CheckRootCode root | root == expected -> pure (Right ())
  DiscoverQueries root | root == expected -> pure (Right [])
  ValidateRoot root | root == expected -> pure (Right report)
  _ -> error "Candidate checking changed roots or executed a query"

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

storageRejected :: Show a => Either OperationalFailure a -> IO ()
storageRejected (Left (StorageUnavailable _)) = pure ()
storageRejected other = fail ("Expected storage failure: " ++ show other)
