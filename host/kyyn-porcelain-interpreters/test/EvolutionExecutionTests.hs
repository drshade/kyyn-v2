{-# LANGUAGE GADTs, OverloadedStrings, LambdaCase #-}
module EvolutionExecutionTests (evolutionExecutionTests) where

import Kyyn.Domain.Curation (emptyCurationRegister)
import Control.Monad (unless, forM_)
import qualified Data.ByteString as Bytes
import Data.IORef (IORef, newIORef, modifyIORef', readIORef)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.EvolutionReport (EvolutionReport(..))
import Kyyn.Domain.Failure
import Kyyn.Domain.FileTree
import Kyyn.Domain.Git
import Kyyn.Domain.KnowledgeBase
import Kyyn.Domain.Path
import Kyyn.Domain.Root
import Kyyn.Domain.Workspace
import Kyyn.Types.Evolution (EvolutionFailure(..))
import qualified Kyyn.Types.KnowledgeBase as KB
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..), RoleDecl(..), Affordance(..))
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation(..))
import Kyyn.Plumbing.Capability.GuestCompilation.Types (sourceFiles)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import GuestFixture
import Kyyn.Plumbing.Capability.SchemaInspection
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Porcelain.Capability.EvolutionExecution (evaluateEvolution)
import Kyyn.Porcelain.Capability.RootStore (loadRootValueForChecking)
import Kyyn.Porcelain.Interpreter.EvolutionExecution (runEvolutionExecution)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import System.Directory (findExecutable)
import System.IO.Temp (withSystemTempDirectory)

evolutionExecutionTests :: RootContract -> FileTree -> IO ()
evolutionExecutionTests contract facts = withSystemTempDirectory "kyyn-evolution-execution" $ \directory -> do
  scope <- right (directoryScope directory)
  shell <- findExecutable "sh" >>= maybe (fail "sh required for process fixtures") pure
  revision <- right (gitRevision (replicate 40 'a'))
  identifier <- right (evolutionId "abc")
  let path = either error id . relativePath
      tree = either error id . fileTree . map (\(p,b) -> (path p,b))
      kb = KnowledgeBase (Repository scope) (Subtree (path "nested"))
      sdk = tree [("Sdk.hs","installed SDK")]
      before = tree [("Example.hs","schema"),("Helper.hs","helper"),("Checks.hs","old checks")]
      code = tree [("kb.dhall",manifest),("src/Example.hs","schema"),("src/Helper.hs","helper"),("src/Checks.hs","old checks")]
      target = tree [("kb.dhall",manifest),("src/Example.hs","schema"),("src/Helper.hs","helper"),("src/Checks.hs","new checks")]
      root = Root contract facts code emptyCurationRegister []
      prepared = SourceRoot contract target (RootDefinition "Example.Root" "Example.metadata" "Checks.validate" [] []
        (tree [("Example.hs","schema"),("Helper.hs","helper"),("Checks.hs","new checks")])) []
      capture proposed = CapturedEvolution (EvolutionContext kb identifier (Before revision contract)
        (WorkspaceSnapshot (WorkspaceManifest revision "Test" "Review" Draft)
          before proposed (tree [("Evolution.hs","captured entry")]) (tree []))) root [path "Example.hs",path "Helper.hs"] prepared
      entry = fixtureProgram
      execute compilation source (CapturedEvolution context _ closure after) = do
        count <- newIORef 0
        result <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
          . runFixtureExecution shell . compileMock compilation . schemaMock count contract . runDhallHandling
          . runRootStore . runEvolutionExecution sdk $ evaluateEvolution (CapturedEvolution context source closure after)
        inspections <- readIORef count
        case result of
          Right (Right _) -> unless (inspections == 0)
            (fail "Execution must consume the prepared target without inspecting again")
          _ -> pure ()
        pure result
      identityEntry = Right (entry "printf '{\"tag\":\"Succeeded\",\"value\":{\"after\":%s,\"steps\":[],\"curation\":{\"tag\":\"None\"}}}' \"$input\"")
      captured = capture target
  expected <- (runEff . runDhallHandling . runRootStore $ loadRootValueForChecking root) >>= right
  result <- execute identityEntry root captured
  unless (result == Right (Right (EvaluatedEvolution captured (After contract) (KB.KnowledgeBase expected []) (EvolutionReport [] Nothing))))
    (fail ("Execution lost selected Before or captured context: " ++ show result))
  let errors = [errorDiagnostic "guest.compiler-rejected" "bad evolution type"]
  compilation <- execute (Left errors) root captured
  unless (compilation == Right (Left (ProposedCodeRejected [errorDiagnostic "evolution.compiler-rejected" "bad evolution type"]))) (fail "Compile failure became guest refusal")
  refusal <- execute (Right (entry "printf '{\"tag\":\"Rejected\",\"value\":[]}'")) root captured
  unless (refusal == Right (Left (EvolutionRejected (EvolutionFailure [])))) (fail "Guest refusal lost its classification")
  invalidOutput <- execute (Right (entry "printf '{\"tag\":\"Succeeded\",\"value\":{\"after\":{\"facts\":null,\"recipes\":[]},\"steps\":[],\"curation\":{\"tag\":\"None\"}}}'")) root captured
  case invalidOutput of
    Right (Left (ProposedCodeRejected _)) -> pure ()
    _ -> fail "Host output rejection was misclassified as guest refusal"
  forM_ [("exit 17",WaitForExit),("printf '{}'",ReadOutput)] $ \(script,operation) -> do
    failure <- execute (Right (entry script)) root captured
    case failure of
      Left (RuntimeUnavailable (ProcessDiagnostic actual _)) | actual == operation -> pure ()
      _ -> fail ("Runtime failure became preview rejection: " ++ show failure)
  let unexpected = error "Invalid preparation reached compilation"
  forM_ [capture (tree [("kb.dhall","True")]),
    capture (tree [("kb.dhall",manifest),("src/Example.hs","different schema")]),
    capture (tree [("kb.dhall",manifest),("src/Example.hs","schema"),("src/Example.lhs","competing module")]),
    capture (tree [("kb.dhall",manifest),("src/Example.hsc","competing module")])] $ \invalid -> do
      rejected <- execute unexpected root invalid
      case rejected of Right (Left (ProposedCodeRejected _)) -> pure (); _ -> fail (show rejected)
  let Root selected _ selectedCode _ _ = root
  unreadable <- execute unexpected (Root selected (tree []) selectedCode emptyCurationRegister []) captured
  case unreadable of Right (Left (ProposedCodeRejected _)) -> pure (); _ -> fail (show unreadable)
  let SchemaMetadata roles assignments collections = metadataOf (rootSchema contract)
  different <- right (checkContract (rootType (rootSchema contract))
    (SchemaMetadata (RoleDecl "extra" "Changed" Title : roles) assignments collections) >>= checkRootLayout)
  mismatch <- execute unexpected (Root different facts code emptyCurationRegister []) captured
  case mismatch of Right (Left (ProposedCodeRejected _)) -> pure (); _ -> fail "Loaded contract mismatch reached execution"
  let changedCode = tree [("kb.dhall",manifest),("src/Example.hs","changed source")]
  sourceMismatch <- execute unexpected (Root contract facts changedCode emptyCurationRegister []) captured
  case sourceMismatch of Right (Left (ProposedCodeRejected _)) -> pure (); _ -> fail "Changed Before copy reached execution"
  putStrLn "Evolution execution selects exact Before, deduplicates its closure and preserves rejection/failure layers."
  where
    manifest = "{ schemaType = \"Example.Root\", schemaMetadata = \"Example.metadata\", validator = \"Checks.validate\", queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }"

schemaMock :: IOE :> es => IORef Int -> RootContract -> Eff (SchemaInspection : es) a -> Eff es a
schemaMock count contract = interpret $ \_ -> \case
  InspectType {} -> error "Unexpected plain type inspection"
  InspectSchema source -> do
    liftIO (modifyIORef' count (+1))
    pure $ if selectedType source == "Example.Root"
      then Right (InspectedSchema (rootSchema contract) [path "Example.hs",path "Helper.hs"])
      else Left [errorDiagnostic "schema.compiler-rejected" "Missing intermediate export"]
  where path = either error id . relativePath

compileMock :: Either [Diagnostic] CompiledProgram -> Eff (GuestCompilation : es) a -> Eff es a
compileMock result = interpret $ \_ -> \case
  CompileGuest sources -> do
    let entries = [(relativeName p,b) | (p,b) <- sourceFiles sources]
    unless (lookup "Checks.hs" entries == Just "new checks" && lookup "Helper.hs" entries == Just "helper" &&
      lookup "Evolution.hs" entries == Just "captured entry" &&
      maybe False (Bytes.isInfixOf "selected = pure . evaluateEvolution Evolution.evolution") (lookup "KyynEvolutionEntry.hs" entries) &&
      maybe False (Bytes.isInfixOf "Program NoRequests") (lookup "KyynEvolutionEntry.hs" entries) &&
      maybe False (Bytes.isInfixOf "edit = Internal.edit afterRoot") (lookup "Kyyn/Workspace/Evolution.hs" entries))
      (error "Execution sources did not preserve target/helpers/generated steps or included old checks")
    pure result

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
