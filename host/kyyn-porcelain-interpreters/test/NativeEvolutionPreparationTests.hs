-- Real target-built descriptors and RootStore material decoding. Git/workspace
-- supply immutable fixture bytes; compilation is fixed to a real Nix discovery
-- artifact and refuses every accepted-lock/schema fallback or second build.
{-# LANGUAGE GHC2021, GADTs, OverloadedStrings, OverloadedRecordDot, DataKinds, TypeFamilies #-}
module Main (main) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Data.Aeson (Value(..), object, (.=))
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.List (stripPrefix, isPrefixOf)
import Effectful (Eff, (:>), DispatchOf, Dispatch(..), runEff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.State.Static.Local (State, runState, modify)
import System.Environment (getArgs)
import System.Directory (canonicalizePath)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Domain.Path
import Kyyn.Domain.FileTree (FileTree, files, fileTree)
import Kyyn.Domain.Git (Repository(..), gitRevision, TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Workspace
import Kyyn.Domain.Evolution
import Kyyn.Domain.Root (Root(..), SourceRoot(..), CheckedValue(..))
import qualified Kyyn.Domain.Recipe as R
import Kyyn.Domain.Guest (InspectedSchema(..), checkedEntries)
import Kyyn.Domain.Contract (contractId, checkRootLayout)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (Recipe(..), FlowEntryRef(..))
import qualified Kyyn.Types.Guest as G
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestInspection (describeGuest)
import Kyyn.Plumbing.Capability.Git (Git(..))
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection)
import Kyyn.Plumbing.Interpreter.GuestInspection (runGuestInspection)
import Kyyn.Plumbing.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Porcelain.Capability.RootOpening (loadRootMaterialWithContracts)
import Kyyn.Porcelain.Capability.RootStore (materializeRoot, encodeRootRecipes, loadRootValueForChecking)
import Kyyn.Porcelain.Capability.EvolutionStore (EvolutionStore(..))
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Protocol.EvolutionPreparation (prepareEvolution)

main :: IO ()
main = do
  arguments <- getArgs
  executable <- case arguments of [selected] -> canonicalizePath selected; _ -> fail "Expected target-built evolution discovery guest"
  let path = either error id . relativePath
      fixture = "tools/fixtures/evolution-guest/"
      program = CompiledProgram (BuildIdentity "fixture" "x86_64-linux" "fixture.drv" (takeDirectory (takeDirectory executable))) executable ".build/evolution-states-api"
  before <- readTree (fixture ++ ".kyyn-before/") ["Before.hs","Annotations.hs","BeforeProgress.hs","BeforeFlows.hs"]
  targetSources <- readTree (fixture ++ "src/") ["After.hs","Annotations.hs"]
  manifest <- Bytes.readFile (fixture ++ "kb.dhall")
  let oldManifest = Text.encodeUtf8 (Text.replace "After.Root" "Before.Root" (Text.decodeUtf8 manifest))
  acceptedCode <- right (fileTree
    ([(path "kb.dhall",oldManifest),(path "flake.nix","accepted flake must never run"),(path "flake.lock","invalid old lock")] ++
     [(path ("src/" ++ relativeName name),value) | (name,value) <- files before]))
  target <- right (fileTree
    ([(path "kb.dhall",manifest),(path "flake.nix","{}"),(path "flake.lock","{} ")] ++
     [(path ("src/" ++ relativeName name),value) | (name,value) <- files targetSources]))
  change <- right (fileTree [(path "Evolution.hs","module Evolution where\nunfinished =\n")])
  empty <- right (fileTree [])
  identity <- right (evolutionId "000001-target-lock")
  withSystemTempDirectory "kyyn-evolution-preparation" $ \directory -> do
    scope <- right (directoryScope directory)
    inspected <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection $ describeGuest program
    description <- right =<< right inspected
    schema <- case [value.contract | G.ContractEntry "$before" value <- checkedEntries description] of
      [selected] -> pure selected
      _ -> fail "Missing target-built Before contract"
    beforeRoot <- right (checkRootLayout schema)
    let state entry = case [value.contract | G.ContractEntry name value <- checkedEntries description, name == entry] of
          [contract] -> contract
          _ -> error "Missing target-built Before recipe state"
        recipe key method name entry value = Fact (FactId key)
          (R.StoredRecipe method name (state entry) (CheckedValue (contractId (state entry)) value))
        recipes = [recipe "unit" (OpenAgent "Review") "()" "$before.state.()" (object []),
          recipe "progress" (OpenAgent "Review") "BeforeProgress.State" "$before.state.BeforeProgress.State" (object ["completed" .= String "3"]),
          recipe "closed" (ClosedAgent (FlowEntryRef "BeforeFlows.review")) "BeforeFlows.State" "$before.flow.BeforeFlows.review" (object ["reviewed" .= String "4"])]
        facts = object ["items" .= ([] :: [Value])]
    stored <- right $ runPureEff . runDhallHandling . runRootStore $ runExceptT $ do
      Root _ values _ _ <- ExceptT (materializeRoot beforeRoot acceptedCode (R.KnowledgeBase (CheckedValue (contractId schema) facts) recipes))
      definitions <- ExceptT (encodeRootRecipes recipes)
      pure (values,definitions)
    accepted <- right (fileTree (files acceptedCode ++ files (fst stored) ++ files (snd stored)))
    let repository = Repository scope
        revision = either error id (gitRevision (replicate 40 '1'))
        kb = KnowledgeBase repository WholeTree
        workspace = EvolutionWorkspace kb identity
        snapshot = WorkspaceSnapshot (WorkspaceManifest revision "Target lock" "" Draft AdHoc) before target change empty
    result <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection . runState @Int 0
      . fixedCompilation program . snapshotGit accepted . workspaceStore snapshot . unexpected @SchemaInspection
      . runRootStore . runRootOpening $ runExceptT $ do
        PreparedEvolution _ source@(SourceRoot contract _ _ _) _ contracts <- ExceptT (prepareEvolution workspace)
        root@(Root _ _ _ loaded) <- ExceptT (loadRootMaterialWithContracts repository revision (Subtree (path "root")) source contracts)
        value <- ExceptT (loadRootValueForChecking root)
        pure (contract,loaded,value)
    (outcome,builds) <- right result
    (actual,loaded,value) <- right outcome
    unless (builds == 1 && actual == beforeRoot && loaded == recipes && value == CheckedValue (contractId schema) facts)
      (fail "Preparation/material loading did not use the target-built contracts exactly once")
  putStrLn "Evolution preparation and recipe-state material loading use only target-built contracts; accepted flake and lock are never built."

readTree :: FilePath -> [FilePath] -> IO FileTree
readTree directory names = mapM (\name -> (,) (either error id (relativePath name)) <$> Bytes.readFile (directory ++ name)) names >>= right . fileTree

fixedCompilation :: State Int :> es => CompiledProgram -> Eff (GuestCompilation : es) a -> Eff es a
fixedCompilation program = interpret $ \_ (CompileGuest source) -> case selectedBuild source of
  EvolutionEntries (EvolutionSelection "Before.Root" "Annotations.metadata" references Nothing (Just []))
    | length references == 3,
      lookup (either error id (relativePath "flake.lock")) (sourceFiles source) == Just "{} " -> do
        modify @Int (+1)
        pure (Right program)
  _ -> error "Preparation attempted an accepted-lock or independent recipe/schema build"

snapshotGit :: FileTree -> Eff (Git : es) a -> Eff es a
snapshotGit tree = interpret $ \_ operation -> case operation of
  ReadTreeAt _ _ location exclusions -> pure (Right (subtree location exclusions))
  ReadFileAt _ _ name -> pure (Right (lookup (relativeName name) repository))
  ReadDirectoryAt _ _ location -> pure (Right (if null (files (subtree location [])) then Nothing else Just []))
  _ -> error "Unexpected Git mutation in preparation"
  where
    repository = [("root/" ++ relativeName name,value) | (name,value) <- files tree]
    subtree :: TreePath -> [RelativePath] -> FileTree
    subtree location exclusions = either error id . fileTree $
      [(either error id (relativePath name),value) | (path,value) <- repository,
       Just name <- [stripPrefix (case location of WholeTree -> ""; Subtree selected -> relativeName selected ++ "/") path],
       not (any (\excluded -> name == relativeName excluded || (relativeName excluded ++ "/") `isPrefixOf` name) exclusions)]
workspaceStore :: WorkspaceSnapshot -> Eff (EvolutionStore : es) a -> Eff es a
workspaceStore snapshot = interpret $ \_ operation -> case operation of
  ReadWorkspace _ -> pure (Right snapshot)
  _ -> error "Unexpected workspace mutation in preparation"
unexpected :: DispatchOf effect ~ Dynamic => Eff (effect : es) a -> Eff es a
unexpected = interpret (\_ _ -> error "Unexpected accepted-environment schema inspection")
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
