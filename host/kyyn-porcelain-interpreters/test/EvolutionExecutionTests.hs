-- Recording compiler/schema with real process/Dhall/filesystem: captured input
-- reuse, closure conflicts, endpoint generation and preparation/runtime/protocol
-- refusals. Forbids redundant source reopening or schema inspection.

{-# LANGUAGE GADTs, OverloadedStrings, LambdaCase #-}
module EvolutionExecutionTests (evolutionExecutionTests) where


import Control.Monad (unless, forM_)
import Data.Aeson (encode, object, (.=), Value(..))
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
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
import qualified Kyyn.Domain.Recipe as KB
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..), RoleDecl(..), Affordance(..))
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation(..))
import Kyyn.Plumbing.Capability.GuestCompilation.Types (sourceFiles, selectedBuild, GuestSelection(..), EvolutionSelection(..))
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import GuestFixture
import Kyyn.Plumbing.Capability.GuestInspection
import Kyyn.Domain.Guest (checkGuest)
import qualified Kyyn.Types.Guest as G
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
      before = tree [("Example.hs","schema"),("Helper.hs","helper"),("Checks.hs","old checks")]
      code = tree [("kb.dhall",manifest),("src/Example.hs","schema"),("src/Helper.hs","helper"),("src/Checks.hs","old checks"),("flake.nix","recorded fixture"),("flake.lock","recorded lock")]
      target = tree [("kb.dhall",manifest),("src/Example.hs","schema"),("src/Helper.hs","helper"),("src/Checks.hs","new checks"),("flake.nix","recorded fixture"),("flake.lock","recorded lock")]
      root = Root contract facts code []
      prepared = SourceRoot contract target (RootDefinition "Example.Root" "Example.metadata" "Checks.validate" [] []
        (tree [("Example.hs","schema"),("Helper.hs","helper"),("Checks.hs","new checks")]) []) []
      capture proposed = CapturedEvolution (EvolutionContext kb identifier (Before revision contract)
        (WorkspaceSnapshot (WorkspaceManifest revision "Test" "Review" Draft AdHoc)
          before proposed (tree [("Evolution.hs","captured entry")]) (tree []))) root [path "Example.hs",path "Helper.hs"] prepared
      entry = fixtureProgram
      execute compilation source (CapturedEvolution context _ closure after) = do
        count <- newIORef 0
        result <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
          . runFixtureExecution shell . compileMock compilation . descriptionMock count contract . runDhallHandling
          . runRootStore . runEvolutionExecution $ evaluateEvolution (CapturedEvolution context source closure after)
        inspections <- readIORef count
        case result of
          Right (Right _) -> unless (inspections == 1)
            (fail "Execution must describe its retained artifact exactly once")
          _ -> pure ()
        pure result
      captured = capture target
  expected@(CheckedValue _ inputValue) <- (runEff . runDhallHandling . runRootStore $ loadRootValueForChecking root) >>= right
  let response = object ["tag" .= ("Succeeded" :: String),"value" .= object
        ["after" .= object ["facts" .= inputValue,"recipes" .= ([] :: [Value])],"steps" .= ([] :: [Value])]]
      quote text = "'" ++ concatMap (\c -> if c == '\'' then "'\\''" else [c]) text ++ "'"
      identityEntry = Right (entry ("printf '%s' " ++ quote (Text.unpack (Text.decodeUtf8 (Lazy.toStrict (encode response))))))
  result <- execute identityEntry root captured
  unless (result == Right (Right (EvaluatedEvolution captured (After contract) (KB.KnowledgeBase expected []) (EvolutionReport [] []))))
    (fail ("Execution lost selected Before or captured context: " ++ show result))
  let errors = [errorDiagnostic "guest.compiler-rejected" "bad evolution type"]
  compilation <- execute (Left errors) root captured
  unless (compilation == Right (Left (ProposedCodeRejected [errorDiagnostic "evolution.compiler-rejected" "bad evolution type"]))) (fail "Compile failure became guest refusal")
  refusal <- execute (Right (entry "printf '{\"tag\":\"Rejected\",\"value\":[]}'")) root captured
  unless (refusal == Right (Left (EvolutionRejected (EvolutionFailure [])))) (fail "Guest refusal lost its classification")
  invalidOutput <- execute (Right (entry "printf '{\"tag\":\"Succeeded\",\"value\":{\"after\":{\"facts\":null,\"recipes\":[]},\"steps\":[]}}'")) root captured
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
  let Root selected _ selectedCode _ = root
  unreadable <- execute unexpected (Root selected (tree []) selectedCode []) captured
  case unreadable of Right (Left (ProposedCodeRejected _)) -> pure (); _ -> fail (show unreadable)
  let SchemaMetadata roles assignments collections = metadataOf (rootSchema contract)
  different <- right (checkContract (descriptionOf (rootSchema contract))
    (SchemaMetadata (RoleDecl "extra" "Changed" Title : roles) assignments collections) >>= checkRootLayout)
  mismatch <- execute unexpected (Root different facts code []) captured
  case mismatch of Right (Left (ProposedCodeRejected _)) -> pure (); _ -> fail "Loaded contract mismatch reached execution"
  let changedCode = tree [("kb.dhall",manifest),("src/Example.hs","changed source")]
  sourceMismatch <- execute unexpected (Root contract facts changedCode []) captured
  case sourceMismatch of Right (Left (ProposedCodeRejected _)) -> pure (); _ -> fail "Changed Before copy reached execution"
  putStrLn "Evolution execution selects exact Before, deduplicates its closure and preserves rejection/failure layers."
  where
    manifest = "{ schemaType = \"Example.Root\", schemaMetadata = \"Example.metadata\", validator = \"Checks.validate\", queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }"

descriptionMock :: IOE :> es => IORef Int -> RootContract -> Eff (GuestInspection : es) a -> Eff es a
descriptionMock count contract = interpret $ \_ (DescribeGuest _) -> do
  liftIO (modifyIORef' count (+1))
  let described = G.describeContract (descriptionOf (rootSchema contract)) (metadataOf (rootSchema contract)) []
  pure (checkGuest (G.GuestDescription G.protocolIdentity
    [G.EvolutionEntry "evolve" (G.AdHocContracts described described)] []))

compileMock :: Either [Diagnostic] CompiledProgram -> Eff (GuestCompilation : es) a -> Eff es a
compileMock result = interpret $ \_ (CompileGuest sources) -> do
  let entries = [(relativeName p,b) | (p,b) <- sourceFiles sources]
  unless (selectedBuild sources == EvolutionEntries (EvolutionSelection "Example.Root" "Example.metadata" [] Nothing Nothing)
    && lookup "src/Checks.hs" entries == Just "new checks" && lookup "src/Helper.hs" entries == Just "helper"
    && lookup ".kyyn-before/Example.hs" entries == Just "schema" && lookup "flake.lock" entries == Just "recorded lock")
    (error "Execution did not preserve target, Before source and target lock")
  pure result

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
