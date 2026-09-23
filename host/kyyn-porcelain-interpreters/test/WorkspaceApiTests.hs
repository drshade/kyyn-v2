{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module WorkspaceApiTests (workspaceApiTests) where

import Control.Monad (unless)
import qualified Data.ByteString.Char8 as Bytes
import Data.IORef (newIORef, modifyIORef', readIORef)
import Effectful (Eff, IOE, (:>), runEff, liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.FileTree
import Kyyn.Domain.Git
import Kyyn.Domain.GuestApi
import Kyyn.Domain.KnowledgeBase
import Kyyn.Domain.Path
import Kyyn.Domain.Root
import Kyyn.Domain.Workspace
import Kyyn.Types.SchemaMetadata
import qualified Kyyn.Plumbing.Capability.ApiInspection as Api
import qualified Kyyn.Plumbing.Capability.Git as Git
import qualified Kyyn.Plumbing.Capability.SchemaInspection as Schema
import Kyyn.Plumbing.Capability.GuestCompilation.Types (sourceFiles)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import qualified Kyyn.Porcelain.Capability.EvolutionStore as Store
import Kyyn.Porcelain.Capability.WorkspaceApi (inspectWorkspaceApi)
import Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Interpreter.WorkspaceApi (runWorkspaceApi)

workspaceApiTests :: IO ()
workspaceApiTests = do
  let path = either error id . relativePath
      tree = either error id . fileTree . map (\(p,b) -> (path p,b))
      contract name = either (error . show) id $ checkContract
        (Algebraic (name ++ ".Root") [] [Constructor (name ++ ".Root") []])
        (SchemaMetadata [] [] []) >>= checkRootLayout
      revision = either error id (gitRevision (replicate 40 'b'))
      repo = Repository (either error id (directoryScope "/fixture"))
      kb = KnowledgeBase repo (Subtree (path "nested"))
      workspace = EvolutionWorkspace kb (either error id (evolutionId "000001-test"))
      before = tree [("Before.hs","before schema"),("Unused.hs","invalid unused code")]
      beforeCode = tree [("kb.dhall",manifest "Before"),("src/Before.hs","before schema"),
        ("src/Unused.hs","invalid unused code"),("examples/retained","example")]
      target = tree [("kb.dhall",manifest "After"),("src/After.hs","after schema")]
      sdk = tree [("Sdk.hs","installed sdk")]
      snapshot beforeCopy targetCode change = WorkspaceSnapshot
        (WorkspaceManifest revision "Test" "" Draft) beforeCopy targetCode change (tree [])
      expected = map (\name -> ApiModule name [])
        ["Kyyn.Workspace.Evolution","Kyyn.Workspace.Before","Kyyn.Workspace.After"]
      perform :: WorkspaceSnapshot -> IO (Either [Diagnostic] WorkspaceCatalogue, [String])
      perform material = do
        trace <- newIORef ([] :: [String])
        let record :: IOE :> es => String -> Eff es ()
            record value = liftIO (modifyIORef' trace (++ [value]))
        result <- runEff
          . interpret (\_ (Api.InspectApiModules source names) -> do
              record "api"
              let entries = [(relativeName p,b) | (p,b) <- files source]
              unless (names == map (\(ApiModule name _) -> name) expected
                && lookup "Before.hs" entries == Just "before schema"
                && lookup "Evolution.hs" entries == Nothing && lookup "Unused.hs" entries == Nothing
                && lookup "Sdk.hs" entries == Just "installed sdk")
                (error "Discovery included evolution/unused code or lost its captured closure")
              pure (Right expected))
          . interpret (\_ -> \case
              Schema.InspectType {} -> error "Unexpected plain type inspection"
              Schema.InspectSchema source -> do
                record ("schema:" ++ Schema.selectedType source)
                let entries = sourceFiles (Schema.schemaSources source)
                unless (all (not . isFactPath . fst) entries) (error "Schema inspection received facts")
                pure $ case Schema.selectedType source of
                  "Before.Root" -> Right (Schema.InspectedSchema (rootSchema (contract "Before")) [path "Before.hs"])
                  "After.Root" -> Right (Schema.InspectedSchema (rootSchema (contract "After")) [path "After.hs"])
                  _ -> Left [errorDiagnostic "test.bad-schema" "Invalid target schema"])
          . interpret (\_ -> \case
              Git.ReadTreeAt selected base location exclusions
                | (selected,base,location,exclusions) == (repo,revision,Subtree (path "nested/root"),[factsLocation, curationLocation, recipesLocation]) -> do
                    record "before"
                    pure (Right beforeCode)
              _ -> error "Discovery read facts, HEAD, history or wrote Git state")
          . interpret (\_ -> \case
              Store.ReadWorkspace selected | selected == workspace -> record "workspace" >> pure (Right material)
              _ -> error "Discovery accessed candidates, lifecycle or persistence")
          . runDhallHandling . runRootStore . runRootOpening sdk . runWorkspaceApi sdk $
              inspectWorkspaceApi workspace
        events <- readIORef trace
        pure (result,events)
  let expectedTrace = ["workspace","before","schema:Before.Root","schema:After.Root","api"]
  (result,events) <- perform (snapshot before target (tree [("Evolution.hs","not valid Haskell")]))
  assert "source-only discovery" (result == Right (WorkspaceCatalogue workspace revision expected) && events == expectedTrace)
  (absent,_) <- perform (snapshot before target (tree []))
  assert "missing evolution body" (absent == result)
  (same,sameTrace) <- perform (snapshot before beforeCode (tree []))
  assert "same-schema discovery" (same == result && sameTrace == take 3 expectedTrace ++ ["schema:Before.Root","api"])
  (mismatch,mismatchTrace) <- perform (snapshot (tree []) target (tree []))
  assert "Before mismatch stops before target inspection" (refused mismatch && mismatchTrace == take 3 expectedTrace)
  (invalid,invalidTrace) <- perform (snapshot before (tree [("kb.dhall",manifest "Rejected"),("src/After.hs","bad")]) (tree []))
  assert "invalid target stops before API inspection" (refused invalid && invalidTrace == take 3 expectedTrace ++ ["schema:Rejected.Root"])
  (repaired,_) <- perform (snapshot before target (tree []))
  assert "repair does not reuse a failed/stale catalogue" (repaired == result)
  (collision,collisionTrace) <- perform (snapshot before
    (tree [("kb.dhall",manifest "Before"),("src/Before.hs","different code")]) (tree []))
  assert "source collision stops before API inspection" (refused collision && collisionTrace == take 3 expectedTrace ++ ["schema:Before.Root"])
  putStrLn "Workspace discovery prepares endpoints once and excludes facts, candidates and evolution execution."

manifest :: String -> Bytes.ByteString
manifest name = Bytes.pack ("{ schemaType = " ++ show (name ++ ".Root") ++
  ", schemaMetadata = " ++ show (name ++ ".metadata") ++
  ", validator = \"Validate.validate\", queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }")

assert :: String -> Bool -> IO ()
assert label ok = unless ok (fail label)

refused :: Either a b -> Bool
refused (Left _) = True
refused _ = False
