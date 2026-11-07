-- Recorded target guest plus real manifest/store/Dhall: discovery builds once,
-- reads accepted bytes without its lock, verifies Before copies, reports failure
-- and repairs without stale state. Real source closure/GHC checks live in the
-- source-merging and Nix workspace-discovery fixtures.
{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module WorkspaceApiTests (workspaceApiTests) where

import Control.Monad (unless)
import qualified Data.ByteString.Char8 as Bytes
import Data.IORef (newIORef, modifyIORef', readIORef)
import Effectful (Eff, IOE, (:>), runEff, liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.FileTree
import Kyyn.Domain.Git
import Kyyn.Domain.Guest (checkGuest)
import Kyyn.Domain.GuestApi
import Kyyn.Domain.KnowledgeBase
import Kyyn.Domain.Path
import Kyyn.Domain.Root
import Kyyn.Domain.Workspace
import Kyyn.Types.SchemaMetadata
import qualified Kyyn.Types.Contract as D
import qualified Kyyn.Types.Guest as G
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestInspection
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Store
import Kyyn.Porcelain.Capability.WorkspaceApi (inspectWorkspaceApi)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Interpreter.WorkspaceApi (runWorkspaceApi)
import GuestFixture (fixtureProgram)

workspaceApiTests :: IO ()
workspaceApiTests = do
  let path = either error id . relativePath
      tree = either error id . fileTree . map (\(p,b) -> (path p,b))
      described name source = G.describeContract
        (D.NamedDescription (D.TypeIdentity "fixture" name "Root" []) (D.RecordDescription "Root" D.NamedFields []))
        (SchemaMetadata [] [] []) [source]
      revision = either error id (gitRevision (replicate 40 'b'))
      repo = Repository (either error id (directoryScope "/fixture"))
      kb = KnowledgeBase repo (Subtree (path "nested"))
      workspace = EvolutionWorkspace kb (either error id (evolutionId "000001-test"))
      before = tree [("Before.hs","before schema"),("Unused.hs","invalid unused code")]
      beforeCode = tree [("kb.dhall",manifest "Before"),("src/Before.hs","before schema"),
        ("src/Unused.hs","invalid unused code"),("flake.nix","must not build accepted flake"),("flake.lock","invalid accepted lock")]
      target = tree [("kb.dhall",manifest "After"),("src/After.hs","after schema"),("flake.nix","target flake"),("flake.lock","target lock")]
      snapshot beforeCopy targetCode change = WorkspaceSnapshot
        (WorkspaceManifest revision "Test" "" Draft AdHoc) beforeCopy targetCode change (tree [])
      expected = [ModuleDescription name ".kyyn-generated/Fixture.hs" Nothing [] [] |
        name <- ["Kyyn.Workspace.Evolution","Kyyn.Workspace.Before","Kyyn.Workspace.After"]]
      program = fixtureProgram "not executed"
      checked = either (error . show) id (checkGuest (G.GuestDescription G.protocolIdentity
        [G.EvolutionDescriptionEntry (described "Before" ".kyyn-before/Before.hs") (described "After" "src/After.hs") []]
        (ModuleDescription "Private" "src/After.hs" Nothing [] [] : expected)))
      perform :: Bool -> WorkspaceSnapshot -> IO (Either [Diagnostic] WorkspaceCatalogue, [String])
      perform refuseBuild material = do
        trace <- newIORef ([] :: [String])
        let record :: IOE :> es => String -> Eff es ()
            record value = liftIO (modifyIORef' trace (++ [value]))
        result <- runEff
          . interpret (\_ (DescribeGuest actual) -> do
              record "describe"
              unless (actual == program) (error "Discovery described a different artifact")
              pure (Right checked))
          . interpret (\_ (CompileGuest source) -> do
              record "build"
              unless (selectedBuild source == EvolutionEntries (EvolutionSelection "Before.Root" "Before.metadata" [] Nothing (Just []))
                && lookup (path "flake.lock") (sourceFiles source) == Just "target lock"
                && lookup (path ".kyyn-before/Before.hs") (sourceFiles source) == Just "before schema"
                && all (not . isRootMaterial . fst) (sourceFiles source))
                (error "Discovery lost typed target selection or included facts")
              pure (if refuseBuild then Left [errorDiagnostic "guest.build" "Rejected fixture"] else Right program))
          . interpret (\_ -> \case
              Git.ReadTreeAt selected base location exclusions
                | (selected,base,location,exclusions) == (repo,revision,Subtree (path "nested/root"),[factsLocation,recipeStatesLocation]) ->
                    record "before" >> pure (Right beforeCode)
              _ -> error "Discovery read facts, HEAD or wrote Git state")
          . interpret (\_ -> \case
              Store.ReadWorkspace selected | selected == workspace -> record "workspace" >> pure (Right material)
              _ -> error "Discovery accessed candidates, lifecycle or persistence")
          . runDhallHandling . runRootStore . runWorkspaceApi $ inspectWorkspaceApi workspace
        events <- readIORef trace
        pure (result,events)
  let expectedTrace = ["workspace","before","build","describe"]
      selected = snapshot before target (tree [("Evolution.hs","not valid Haskell")])
  (result,events) <- perform False selected
  assert "source-only discovery" (result == Right (WorkspaceCatalogue workspace revision expected) && events == expectedTrace)
  (absent,_) <- perform False (snapshot before target (tree []))
  assert "missing evolution body" (absent == result)
  (mismatch,mismatchTrace) <- perform False (snapshot (tree []) target (tree []))
  assert "Before mismatch stops before build" (refused mismatch && mismatchTrace == take 2 expectedTrace)
  (invalid,invalidTrace) <- perform True selected
  assert "build failure stops before description" (refused invalid && invalidTrace == take 3 expectedTrace)
  (repaired,repairTrace) <- perform False selected
  assert "repair does not reuse failed/stale discovery" (repaired == result && repairTrace == expectedTrace)
  putStrLn "Workspace discovery uses one target build and checked typed description, with no accepted-lock fallback."

manifest :: String -> Bytes.ByteString
manifest name = Bytes.pack ("{ schemaType = " ++ show (name ++ ".Root") ++
  ", schemaMetadata = " ++ show (name ++ ".metadata") ++
  ", validator = \"Validate.validate\", queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }")

assert :: String -> Bool -> IO ()
assert label ok = unless ok (fail label)
refused :: Either a b -> Bool
refused (Left _) = True
refused _ = False
