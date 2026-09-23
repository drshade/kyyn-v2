{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module EvolutionCaptureTests (evolutionCaptureTests) where

import Kyyn.Domain.Curation (emptyCurationRegister)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Data.IORef (IORef, newIORef, modifyIORef', readIORef)
import Effectful (Eff, IOE, (:>), runEff, liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Diagnostic (Diagnostic(..), Severity(Error), errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.Failure (OperationalFailure(..), StorageDiagnostic(..), StorageOperation(WriteFile))
import Kyyn.Domain.FileTree (FileTree, fileTree)
import Kyyn.Domain.Git (Repository(..), GitRevision, TreePath(..), gitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (directoryScope, relativePath)
import Kyyn.Domain.Root (Root(..), SourceRoot(..), RootDefinition(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionState(Draft))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Protocol.Evolution (identityEvolutionSource)
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Porcelain.Capability.EvolutionStore
import Kyyn.Porcelain.Capability.EvolutionAuthoring
import Kyyn.Porcelain.Capability.RootOpening (RootOpening(..))
import Kyyn.Porcelain.Capability.WorkspaceStore (WorkspaceStore)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.EvolutionAuthoring (runEvolutionAuthoring)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import Kyyn.Porcelain.Capability.RootStore (RootStore)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import System.Directory (createDirectoryIfMissing, removeFile, listDirectory)
import System.FilePath ((</>), takeDirectory)
import System.IO.Temp (withSystemTempDirectory)

type TestEffects = '[EvolutionAuthoring, EvolutionStore, RootOpening, Git.Git, WorkspaceStore, RootStore, DhallHandling, FileSystem, Failure, IOE]

evolutionCaptureTests :: RootContract -> IO ()
evolutionCaptureTests contract = withSystemTempDirectory "kyyn-evolution-capture" $ \directory -> do
  forM_ ["", "../a", "a/b", "a\\b", "ABC", "-name", ".name", "a.b", "a b"] $ \bad -> rejected (evolutionId bad)
  forM_
    [ ([], "Review λ", "000001-review")
    , (["000001-start", "000009-finish", "000009-other", "notes", "abc123", "42-short"], " Add / Review STATUS! ", "000010-add-review-status")
    , (["000098-a"], "Sales September", "000099-sales-september")
    ] $ \(names,name,expected) -> do
      identities <- traverse (right . evolutionId) names
      allocated <- right (nextEvolutionId identities (EvolutionName name))
      unless (evolutionIdName allocated == expected) (fail "Incorrect numbered slug allocation")
  final <- right (evolutionId "999999-final")
  rejected (nextEvolutionId [final] (EvolutionName "More"))
  forM_ ["", "!!!", "λ"] $ \name -> rejected (nextEvolutionId [] (EvolutionName name))
  repo <- Repository <$> right (directoryScope directory)
  revision <- right (gitRevision (replicate 40 'a'))
  revisionB <- right (gitRevision (replicate 40 'b'))
  identity <- right (evolutionId "e001")
  missing <- right (evolutionId "e002")
  sourceTree <- tree [("Schema.hs", "selected source"), ("Helpers.hs", "selected helper")]
  sourceCode <- tree [("kb.dhall", "{ schemaType = \"Schema.Root\", schemaMetadata = \"Schema.metadata\", validator = \"Validate.validate\", queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }"), ("src/Schema.hs", "selected source"),
    ("src/Helpers.hs", "selected helper"), ("examples/check.dhall", "selected example"),
    ("plugins/config/provider.dhall", "selected config")]
  expectedClosure <- traverse (right . relativePath) ["Schema.hs", "Helpers.hs"]
  let source = SourceRoot contract sourceCode (RootDefinition "Schema.Root" "Schema.metadata" "Validate.validate" [] [] sourceTree) expectedClosure
  forM_ [Nothing, Just "examples/sales"] $ \prefixName -> do
    prefix <- maybe (pure WholeTree) (fmap Subtree . right . relativePath) prefixName
    rootPath <- Subtree <$> right (relativePath (maybe "root" (++ "/root") prefixName))
    let kb = KnowledgeBase repo prefix
        location = EvolutionWorkspace kb identity
        workspacePath = directory </> maybe "" id prefixName </> "evolutions/e001"
        write path bytes = do
          createDirectoryIfMissing True (takeDirectory (workspacePath </> path))
          Bytes.writeFile (workspacePath </> path) bytes
        execute :: GitRevision -> Either OperationalFailure (Either [Diagnostic] SourceRoot)
          -> Eff TestEffects a
          -> IO (Either OperationalFailure a)
        execute selected answer action = do
          count <- newIORef 0
          result <- runEff . runFailure . runFileSystemIO (case repo of Repository scope -> scope)
            . runDhallHandling . runRootStore . runWorkspaceStore . noGit . openingMock count repo selected rootPath answer
            . runEvolutionStore . runEvolutionAuthoring $ action
          opens <- readIORef count
          unless (opens <= 1) (fail "Capture reopened Before within one operation")
          pure result
        success :: Eff TestEffects a -> IO (Either OperationalFailure a)
        success = execute revision (Right (Right source))
        noOpening :: Eff TestEffects a -> IO (Either OperationalFailure a)
        noOpening = execute revision (error "Input matching/malformed capture unexpectedly opened a source root")
        displayName = "Sales / ../ \"September\" λ"
    created@(EvolutionWorkspace createdKb createdId) <- success (createEvolution kb (EvolutionName displayName) revision) >>= right >>= right
    unless (createdKb == kb && evolutionIdName createdId == "000001-sales-september")
      (fail "Creation returned an invalid KB or directory ID")
    CapturedEvolution (EvolutionContext _ _ (Before createdBase _) (WorkspaceSnapshot
      (WorkspaceManifest _ actualName explanation state) createdBefore createdTarget createdChange createdNotes)) _ _ _ <-
        success (captureEvolution created) >>= right >>= right
    empty <- tree []
    identityEntry <- tree [("Evolution.hs",identityEvolutionSource "Schema.Root")]
    unless (createdBase == revision && actualName == displayName && null explanation && state == Draft &&
      createdBefore == sourceTree && createdTarget == sourceCode && createdChange == identityEntry && createdNotes == empty)
      (fail "Created draft did not capture selected source, full non-fact code and empty editable inputs")
    another@(EvolutionWorkspace _ anotherId) <- success (createEvolution kb (EvolutionName displayName) revision) >>= right >>= right
    unless (another /= created && evolutionIdName anotherId == "000002-sales-september") (fail "Repeated creation did not advance the local sequence")
    let evolutionDirectory = directory </> maybe "" id prefixName </> "evolutions"
        sourceError = [errorDiagnostic "test.source-rejected" "Source schema rejected"]
    beforeRejection <- listDirectory evolutionDirectory
    denied <- execute revision (Right (Left sourceError)) (createEvolution kb (EvolutionName "Bad") revision)
    afterRejection <- listDirectory evolutionDirectory
    unless (denied == Right (Left sourceError) && beforeRejection == afterRejection)
      (fail "Source rejection created a draft or lost diagnostics")
    write "manifest.dhall" (manifest 'a' "Draft")
    write "before/Schema.hs" "selected source"
    write "before/Helpers.hs" "selected helper"
    write "target/kb.dhall" "unfinished target manifest"
    write "target/src/Schema.hs" "unfinished target source"
    write "change/Evolution.hs" "unfinished entry"
    write "notes/review.md" "original note"
    captured@(CapturedEvolution context@(EvolutionContext actualKb actualId (Before base actualContract)
      (WorkspaceSnapshot (WorkspaceManifest manifestBase _ _ _) before target _ _)) input closure _) <-
      success (captureEvolution location) >>= right >>= right
    unless (actualKb == kb && actualId == identity && base == revision && manifestBase == revision && actualContract == contract && before == sourceTree)
      (fail "Capture did not retain its selected KB, workspace, Before revision/contract/source")
    expectedTarget <- tree [("kb.dhall", "unfinished target manifest"), ("src/Schema.hs", "unfinished target source")]
    emptyFacts <- tree []
    unless (input == Root contract emptyFacts sourceCode emptyCurationRegister [] && closure == expectedClosure) (fail "Capture lost its input root or closure")
    unless (target == expectedTarget) (fail "Capture changed proposed target bytes")
    snapshot <- noOpening (readWorkspace location) >>= right >>= right
    unless (case context of EvolutionContext _ _ _ material -> snapshot == material)
      (fail "Store read changed the captured workspace")
    noOpening (matchesCapturedInputs context) >>= right >>= right >>= assertTrue
    write "manifest.dhall" (manifest 'a' "Ready")
    write "notes/review.md" "later note"
    noOpening (matchesCapturedInputs context) >>= right >>= right >>= assertTrue
    write "target/src/Schema.hs" "same type, different source"
    noOpening (matchesCapturedInputs context) >>= right >>= right >>= assertFalse
    write "target/src/Schema.hs" "unfinished target source"
    write "manifest.dhall" (manifest 'b' "Draft")
    noOpening (matchesCapturedInputs context) >>= right >>= right >>= assertFalse
    rebased <- execute revisionB (Right (Right source)) (captureEvolution location) >>= right >>= right
    case rebased of
      CapturedEvolution (EvolutionContext _ _ (Before selected _) _) _ _ _ ->
        unless (selected == revisionB) (fail "Capture reused the old Before revision")
    write "manifest.dhall" (manifest 'a' "Draft")
    write "before/Schema.hs" "edited copy, same schema type"
    mismatch <- success (captureEvolution location) >>= right
    unless (mismatch == Left [errorDiagnostic "evolution.before-mismatch"
      "before/ must match the selected revision's src/ tree; refresh it from that revision"])
      (fail "Edited Before copy did not yield actionable mismatch")
    write "before/Schema.hs" "selected source"
    write "before/Extra.hs" "unselected source"
    success (captureEvolution location) >>= right >>= rejected
    removeFile (workspacePath </> "before/Extra.hs")
    removeFile (workspacePath </> "before/Helpers.hs")
    success (captureEvolution location) >>= right >>= rejected
    write "before/Helpers.hs" "selected helper"
    let diagnostic = [errorDiagnostic "test.source-rejected" "Source schema rejected"]
    sourceRejected <- execute revision (Right (Left diagnostic)) (captureEvolution location)
    unless (sourceRejected == Right (Left diagnostic)) (fail "Source diagnostics were rewritten")
    forM_ [CompilerUnavailable "missing compiler", GitUnavailable "unreadable repository"] $ \failure -> do
      result <- execute revision (Left failure) (captureEvolution location)
      unless (result == Left failure) (fail "Source infrastructure failure became capture rejection")
    write "manifest.dhall" "True"
    noOpening (captureEvolution location) >>= right >>= rejected
    noOpening (matchesCapturedInputs context) >>= right >>= rejected
    write "manifest.dhall" (manifest 'a' "Draft")
    recaptured <- success (captureEvolution location) >>= right >>= right
    case (captured, recaptured) of
      (CapturedEvolution (EvolutionContext _ _ _ original) _ _ _, CapturedEvolution (EvolutionContext _ _ _ current) _ _ _) ->
        unless (original /= current) (fail "Later note unexpectedly changed the original snapshot")
    missingResult <- noOpening (captureEvolution (EvolutionWorkspace kb missing))
    case missingResult of
      Left (StorageUnavailable _) -> pure ()
      _ -> fail "Missing workspace did not remain an operational storage failure"
  let failure = StorageUnavailable (StorageDiagnostic WriteFile "fixture" "write failed")
  rootPath <- Subtree <$> right (relativePath "root")
  count <- newIORef 0
  failedWrite <- runEff . runFailure . creationFiles True failure . runDhallHandling . runRootStore . runWorkspaceStore . noGit
    . openingMock count repo revision rootPath (Right (Right source)) . runEvolutionStore . runEvolutionAuthoring $
      createEvolution (KnowledgeBase repo WholeTree) (EvolutionName "Write failure") revision
  unless (failedWrite == Left failure) (fail "Failed creation write returned a successful workspace")
  collided <- runEff . runFailure . creationFiles False failure . runDhallHandling . runRootStore . runWorkspaceStore . noGit
    . openingMock count repo revision rootPath (Right (Right source)) . runEvolutionStore . runEvolutionAuthoring $
      createEvolution (KnowledgeBase repo WholeTree) (EvolutionName "Collision") revision
  case collided of
    Right (Left [Diagnostic Error "evolution.exists" _ _]) -> pure ()
    _ -> fail "Lost directory reservation wrote files or became a storage failure"
  putStrLn "Evolution capture verifies selected Before copies, KB paths and live input matching."

creationFiles :: Failure :> es => Bool -> OperationalFailure -> Eff (FileSystem : es) a -> Eff es a
creationFiles available failure = interpret $ \_ -> \case
  FS.ListDirectory _ -> pure Nothing
  FS.EnsureDirectory _ -> pure ()
  FS.CreateDirectory _ -> pure available
  FS.WriteBytes {} -> raiseFailure failure
  _ -> error "Creation unexpectedly read files or used a temporary scope"

noGit :: Eff (Git.Git : es) a -> Eff es a
noGit = interpret $ \_ _ -> error "Capture bypassed RootOpening for Git"

openingMock
  :: (Failure :> es, IOE :> es) => IORef Int -> Repository -> GitRevision -> TreePath
  -> Either OperationalFailure (Either [Diagnostic] SourceRoot)
  -> Eff (RootOpening : es) a -> Eff es a
openingMock count expectedRepo expectedRevision expectedPath answer = interpret $ \_ operation -> do
  case operation of
    LoadSourceAt repo revision path
      | (repo, revision, path) == (expectedRepo, expectedRevision, expectedPath) -> do
        liftIO (modifyIORef' count (+1))
        either raiseFailure pure answer
    OpenCapturedSource target -> either raiseFailure (pure . fmap (\(SourceRoot schema _ definition closure) ->
      SourceRoot schema target definition closure)) answer
    LoadRootMaterialAt repo revision path (SourceRoot schema code _ _)
      | (repo, revision, path) == (expectedRepo, expectedRevision, expectedPath) ->
        pure (Right (Root schema (either error id (fileTree [])) code emptyCurationRegister []))
    _ -> error "Capture opened the wrong source revision/path or tried to decode facts"

manifest :: Char -> String -> Bytes.ByteString
manifest digit state = Char8.pack ("{ before = { revision = " ++ show (replicate 40 digit) ++
  " }, name = \"Import\", explanation = \"Bring in sales\", state = < Draft | Ready | Accepted >." ++ state ++
  "}")

tree :: [(FilePath, Bytes.ByteString)] -> IO FileTree
tree entries = traverse (\(p,b) -> do path <- right (relativePath p); pure (path,b)) entries >>= right . fileTree

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

rejected :: Show a => Either e a -> IO ()
rejected (Left _) = pure ()
rejected (Right value) = fail ("Unexpected success: " ++ show value)

assertTrue, assertFalse :: Bool -> IO ()
assertTrue value = unless value (fail "Expected captured inputs to match")
assertFalse value = unless (not value) (fail "Expected captured inputs to differ")
