-- Execute a real Nix evolution artifact through native host capture, endpoint
-- checks, RootStore decoding and report validation. Compilation is fixed to the
-- supplied artifact and rejects selections other than evolution execution.
{-# LANGUAGE GHC2021, GADTs, OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where
import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=))
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (runEff)
import Effectful.Dispatch.Dynamic (interpret)
import System.Environment (getArgs)
import System.Directory (canonicalizePath)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Domain.Path
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Git (Repository(..), TreePath(..), gitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Evolution
import Kyyn.Domain.EvolutionReport (EvolutionReport(..))
import Kyyn.Domain.Workspace
import Kyyn.Domain.Root (SourceRoot(..), RootDefinition(..), CheckedValue(..))
import qualified Kyyn.Domain.Recipe as R
import Kyyn.Domain.Guest (InspectedSchema(..), checkedEntries)
import Kyyn.Domain.Contract (contractId, rootSchema, checkRootLayout)
import qualified Kyyn.Types.Guest as G
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestInspection (describeGuest)
import Kyyn.Plumbing.Interpreter.GuestInspection (runGuestInspection)
import Kyyn.Plumbing.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Porcelain.Capability.RootStore (materializeRoot, readRootDefinition)
import Kyyn.Porcelain.Capability.EvolutionExecution (evaluateEvolution)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Interpreter.EvolutionExecution (runEvolutionExecution)

main :: IO ()
main = do
  arguments <- getArgs
  executable <- case arguments of [selected] -> canonicalizePath selected; _ -> fail "Expected Nix evolution guest"
  let path = either error id . relativePath
      fixture = "tools/fixtures/evolution-guest/"
      program = CompiledProgram (BuildIdentity "fixture" "x86_64-linux" "fixture.drv" (takeDirectory (takeDirectory executable))) executable ".build/evolution-native-handles"
  before <- readTree (fixture ++ ".kyyn-before/") ["Before.hs","Annotations.hs","BeforeProgress.hs","BeforeFlows.hs"]
  after <- readTree (fixture ++ "src/") ["After.hs","Annotations.hs","AfterFlows.hs"]
  change <- readTree (fixture ++ ".kyyn-change/") ["Evolution.hs"]
  manifest <- Bytes.readFile (fixture ++ "kb.dhall")
  let code selected sources = fileTree
        ([(path "kb.dhall",Text.encodeUtf8 (Text.replace "After.Root" selected (Text.decodeUtf8 manifest))),
          (path "flake.nix","{}"),(path "flake.lock","{}")] ++
         [(path ("src/" ++ relativeName name),value) | (name,value) <- files sources])
  accepted <- right (code "Before.Root" before)
  target <- right (code "After.Root" after)
  empty <- right (fileTree [])
  identity <- right (evolutionId "000001-native")
  revision <- right (gitRevision (replicate 40 '1'))
  withSystemTempDirectory "kyyn-native-evolution" $ \directory -> do
    scope <- right (directoryScope directory)
    result <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection
      . interpret @GuestCompilation (\_ (CompileGuest source) -> case selectedBuild source of
          EvolutionEntries (EvolutionSelection _ _ [] Nothing Nothing) -> pure (Right program)
          _ -> error "Unexpected evolution build selection")
      . runRootStore . runEvolutionExecution $ do
        description <- describeGuest program >>= either (error . show) pure
        (old,new) <- case [(old.contract,new.contract) | G.EvolutionEntry _ (G.AdHocContracts old new) <- checkedEntries description] of
          [pair] -> pure pair
          _ -> error "Missing evolution entry"
        let checked = either (error . show) id
            oldRoot = checked (checkRootLayout old)
            newRoot = checked (checkRootLayout new)
            fact value = object ["id" .= String "one","value" .= value]
            facts = object ["items" .= [fact (object ["amount" .= String "7"])]]
        source <- materializeRoot oldRoot accepted (R.KnowledgeBase (CheckedValue (contractId old) facts) []) >>= either (error . show) pure
        definition <- readRootDefinition target >>= either (error . show) pure
        RootDefinition _ _ _ _ _ _ _ <- pure definition
        let kb = KnowledgeBase (Repository scope) WholeTree
            snapshot = WorkspaceSnapshot (WorkspaceManifest revision "Native" "" Draft AdHoc) before target change empty
            captured = CapturedEvolution (EvolutionContext kb identity (Before revision oldRoot) snapshot)
              source [] (SourceRoot newRoot target definition [])
        outcome <- evaluateEvolution captured
        pure (contractId (rootSchema newRoot),outcome)
    (expected,outcome) <- right result
    EvaluatedEvolution _ _ (R.KnowledgeBase (CheckedValue actual facts) recipes) (EvolutionReport changes steps) <- right outcome
    unless (actual == expected && null recipes && null changes && length steps == 1 && facts == object
      ["items" .= [object ["id" .= String "one","value" .= object ["amount" .= String "7","note" .= String "migrated"]]]])
      (fail "Native evolution report/material result differs")
  putStrLn "Native evolution capture, checked endpoint invocation and report validation pass."
readTree :: FilePath -> [FilePath] -> IO FileTree
readTree directory names = mapM (\name -> (,) (either error id (relativePath name)) <$> Bytes.readFile (directory ++ name)) names >>= right . fileTree
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
