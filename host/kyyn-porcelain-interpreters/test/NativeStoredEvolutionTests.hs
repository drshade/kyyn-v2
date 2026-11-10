-- Real target-only guest through host snapshot validation, independent projection,
-- target materialization and report checking. No historical code/schema is loaded.
{-# LANGUAGE GHC2021, OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import qualified Data.ByteString as Bytes
import Effectful (runEff)
import System.Environment (getArgs)
import System.Directory (canonicalizePath)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Domain.Path
import Kyyn.Domain.FileTree (fileTree)
import Kyyn.Domain.CompiledProgram
import Kyyn.Domain.Root (Root(..))
import Kyyn.Domain.SnapshotReport
import Kyyn.Domain.Recipe (RecipeDefinition(..))
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Plumbing.Capability.GuestInspection (describeGuest)
import Kyyn.Plumbing.Interpreter.GuestInspection (runGuestInspection)
import Kyyn.Plumbing.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Protocol.StoredEvolution (executeStoredEvolution)
import Kyyn.Porcelain.Protocol.StoredSnapshot (readStoredSnapshot)
import Kyyn.Porcelain.Protocol.RecipePersistence (encodeRecipes)

main :: IO ()
main = do
  arguments <- getArgs
  executable <- case arguments of [selected] -> canonicalizePath selected; _ -> fail "Expected target-only guest"
  let path = either error id . relativePath
      program = CompiledProgram (BuildIdentity "fixture" "x86_64-linux" "fixture.drv" (takeDirectory (takeDirectory executable)))
        executable ".build/native-target-evolution"
  manifest <- Bytes.readFile "tools/fixtures/target-evolution-guest/kb.dhall"
  code <- right (fileTree [(path "kb.dhall",manifest)])
  withSystemTempDirectory "kyyn-native-target-evolution" $ \directory -> do
    scope <- right (directoryScope directory)
    result <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection . runRootStore . runExceptT $ do
        definitions <- ExceptT (encodeRecipes
          [Fact (FactId "weekly") (ClosedRecipe (FlowEntryRef "Flows.review")),
           Fact (FactId "obsolete") (ClosedRecipe (FlowEntryRef "Missing.obsolete"))])
        let stored = either error id (fileTree
              [(path "facts/root.dhall","{=}"),
               (path "facts/items/index.dhall","[\"one\"]"),
               (path "facts/items/one.dhall","{ id = \"one\", value = { amount = +7 } }"),
               (path "recipes.dhall",definitions),
               (path "recipes/weekly/state.dhall","{ count = +4 }"),
               (path "recipes/obsolete/state.dhall","{=}"),
               (path "src/Schema.hs","this old application does not compile")])
        input <- ExceptT (readStoredSnapshot stored)
        guest <- ExceptT (describeGuest program)
        ExceptT (executeStoredEvolution program guest code (Rationale "Native target migration" []) input)
    (Root _ _ _ recipes,steps) <- right result >>= right
    unless (length recipes == 1 && length steps == 5) (fail "Wrong recipe or observation membership")
    unless ([origin | SnapshotStep origin _ _ <- steps] == [Authored,Authored,Authored,Authored,TargetProjection])
      (fail "Lost the target projection boundary")
  putStrLn "Native stored evolution and independent target projection verification passed"
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
