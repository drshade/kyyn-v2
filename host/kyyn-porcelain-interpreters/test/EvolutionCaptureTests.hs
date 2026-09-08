{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module EvolutionCaptureTests (evolutionCaptureTests) where

import Control.Monad (forM_, unless)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Effectful (Eff, IOE, (:>), runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.Failure (OperationalFailure(..), StorageDiagnostic(..), StorageOperation(WriteFile))
import Kyyn.Domain.FileTree (FileTree, fileTree)
import Kyyn.Domain.Git (Repository(..), GitRevision, TreePath(..), gitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (directoryScope, relativePath)
import Kyyn.Domain.Root (SourceRoot(..), RootDefinition(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), EvolutionState(Draft))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Protocol.Evolution (identityEvolutionSource)
import qualified Kyyn.Plumbing.Capability.FileSystem as FS
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Porcelain.Capability.EvolutionStore
import Kyyn.Porcelain.Capability.RootOpening (RootOpening(..))
import Kyyn.Porcelain.Capability.WorkspaceStore (WorkspaceStore)
import Kyyn.Porcelain.Interpreter.EvolutionStore (runEvolutionStore)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)
import System.Directory (createDirectoryIfMissing, removeFile, listDirectory)
import System.FilePath ((</>), takeDirectory)
import System.IO.Temp (withSystemTempDirectory)

type TestEffects = '[EvolutionStore, RootOpening, WorkspaceStore, DhallHandling, FileSystem, Failure, IOE]

evolutionCaptureTests :: RootContract -> IO ()
evolutionCaptureTests contract = withSystemTempDirectory "kyyn-evolution-capture" $ \directory -> do
  forM_ ["", "../a", "a/b", "ABC", "con", "a.b", "a b"] $ \bad -> rejected (evolutionId bad)
  repo <- Repository <$> right (directoryScope directory)
  revision <- right (gitRevision (replicate 40 'a'))
  revisionB <- right (gitRevision (replicate 40 'b'))
  identity <- right (evolutionId "e001")
  missing <- right (evolutionId "e002")
  sourceTree <- tree [("Schema.hs", "selected source"), ("Helpers.hs", "selected helper")]
  sourceCode <- tree [("kb.dhall", "selected manifest"), ("src/Schema.hs", "selected source"),
    ("src/Helpers.hs", "selected helper"), ("examples/check.dhall", "selected example"),
    ("plugins/config/provider.dhall", "selected config")]
  let source = SourceRoot contract sourceCode (RootDefinition "Schema.Root" "Schema.metadata" "Validate.validate" [] sourceTree)
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
        execute selected answer = runEff . runFailure . runFileSystemIO (case repo of Repository scope -> scope)
          . runDhallHandling . runWorkspaceStore . openingMock repo selected rootPath answer . runEvolutionStore
        success :: Eff TestEffects a -> IO (Either OperationalFailure a)
        success = execute revision (Right (Right source))
        noOpening :: Eff TestEffects a -> IO (Either OperationalFailure a)
        noOpening = execute revision (error "Input matching/malformed capture unexpectedly opened a source root")
        displayName = "Sales / ../ \"September\" λ"
    created@(EvolutionWorkspace createdKb createdId) <- success (createEvolution kb (EvolutionName displayName) revision) >>= right >>= right
    unless (createdKb == kb && Right createdId == evolutionId (evolutionIdName createdId))
      (fail "Creation returned an invalid KB or directory ID")
    CapturedEvolution (EvolutionContext _ _ (Before createdBase _) (WorkspaceSnapshot
      (WorkspaceManifest _ actualName explanation state) createdBefore createdTarget createdChange createdNotes)) <-
        success (captureEvolution created) >>= right >>= right
    empty <- tree []
    identityEntry <- tree [("Evolution.hs",identityEvolutionSource)]
    unless (createdBase == revision && actualName == displayName && null explanation && state == Draft &&
      createdBefore == sourceTree && createdTarget == sourceCode && createdChange == identityEntry && createdNotes == empty)
      (fail "Created draft did not capture selected source, full non-fact code and empty editable inputs")
    another <- success (createEvolution kb (EvolutionName displayName) revision) >>= right >>= right
    unless (another /= created) (fail "Repeated creation reused a workspace")
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
      (WorkspaceSnapshot (WorkspaceManifest manifestBase _ _ _) before target _ _))) <-
      success (captureEvolution location) >>= right >>= right
    unless (actualKb == kb && actualId == identity && base == revision && manifestBase == revision && actualContract == contract && before == sourceTree)
      (fail "Capture did not retain its selected KB, workspace, Before revision/contract/source")
    expectedTarget <- tree [("kb.dhall", "unfinished target manifest"), ("src/Schema.hs", "unfinished target source")]
    unless (target == expectedTarget) (fail "Capture changed proposed target bytes")
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
      CapturedEvolution (EvolutionContext _ _ (Before selected _) _) ->
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
      (CapturedEvolution (EvolutionContext _ _ _ original), CapturedEvolution (EvolutionContext _ _ _ current)) ->
        unless (original /= current) (fail "Later note unexpectedly changed the original snapshot")
    missingResult <- noOpening (captureEvolution (EvolutionWorkspace kb missing))
    case missingResult of
      Left (StorageUnavailable _) -> pure ()
      _ -> fail "Missing workspace did not remain an operational storage failure"
  let failure = StorageUnavailable (StorageDiagnostic WriteFile "fixture" "write failed")
  rootPath <- Subtree <$> right (relativePath "root")
  failedWrite <- runEff . runFailure . failingWrites failure . runDhallHandling . runWorkspaceStore
    . openingMock repo revision rootPath (Right (Right source)) . runEvolutionStore $
      createEvolution (KnowledgeBase repo WholeTree) (EvolutionName "Write failure") revision
  unless (failedWrite == Left failure) (fail "Failed creation write returned a successful workspace")
  putStrLn "Evolution capture verifies selected Before copies, KB paths and live input matching."

failingWrites :: Failure :> es => OperationalFailure -> Eff (FileSystem : es) a -> Eff es a
failingWrites failure = interpret $ \_ -> \case
  FS.CreateUniqueDirectory _ -> pure (either error id (relativePath "e003"))
  FS.WriteBytes {} -> raiseFailure failure
  _ -> error "Creation unexpectedly read files or used a temporary scope"

openingMock
  :: Failure :> es => Repository -> GitRevision -> TreePath
  -> Either OperationalFailure (Either [Diagnostic] SourceRoot)
  -> Eff (RootOpening : es) a -> Eff es a
openingMock expectedRepo expectedRevision expectedPath answer = interpret $ \_ -> \case
  LoadSourceAt repo revision path
    | (repo, revision, path) == (expectedRepo, expectedRevision, expectedPath) -> either raiseFailure pure answer
  _ -> error "Capture opened the wrong source revision/path or tried to decode facts"

manifest :: Char -> String -> Bytes.ByteString
manifest digit state = Char8.pack ("{ before = { revision = " ++ show (replicate 40 digit) ++
  " }, name = \"Import\", explanation = \"Bring in sales\", state = < Draft | Ready | Accepted >." ++ state ++ " }")

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
