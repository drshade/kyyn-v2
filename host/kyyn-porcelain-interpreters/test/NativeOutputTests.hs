-- Real Nix Root guest: query, read trace, checked output binding and sink delivery
-- share one executable. Compilation is not mocked or exercised by this harness;
-- the supplied artifact was built by the output fixture's Nix derivation.
{-# LANGUAGE GHC2021, GADTs, OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (Value(..), object, (.=))
import qualified Data.ByteString as Bytes
import Effectful (runEff)
import System.Directory (canonicalizePath)
import System.Environment (getArgs)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Domain.CompiledProgram (CompiledProgram(..), BuildIdentity(..))
import Kyyn.Domain.Guest (InspectedSchema(..), checkedEntries)
import Kyyn.Domain.Contract (contractId, checkRootLayout, rootSchema)
import Kyyn.Domain.Diagnostic (errorDiagnostic, ValidationReport(..))
import qualified Kyyn.Domain.Recipe as R
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.Path
import Kyyn.Domain.Output (PublicationOutcome(..))
import Kyyn.Domain.Query (QueryDescriptor(..), QueryResult(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Query (ReadAccess(..))
import qualified Kyyn.Types.Guest as G
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation(..), selectedBuild, GuestSelection(..))
import Kyyn.Plumbing.Capability.GuestInspection (describeGuest)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Interpreter.GuestInspection (runGuestInspection)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.Delivery (invokeSink)
import Kyyn.Porcelain.Interpreter.Delivery (runDelivery)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Capability.RootExecution
import Kyyn.Porcelain.Capability.RootStore (materializeRoot)
import Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Effectful.Dispatch.Dynamic (interpret)

main :: IO ()
main = do
  arguments <- getArgs
  executable <- case arguments of [selected] -> canonicalizePath selected; _ -> fail "Expected Nix-built output guest"
  let path = either error id . relativePath
      packageFixture = "tools/fixtures/captured-plugin/"
      program = CompiledProgram (BuildIdentity "fixture" "x86_64-linux" "fixture.drv" (takeDirectory (takeDirectory executable))) executable ".build/output-guest"
  package <- mapM (\name -> (,) (path name) <$> Bytes.readFile (packageFixture ++ name))
    ["kyyn-plugin.dhall","src/Fixture/Plugin.hs"] >>= right . fileTree
  configuration <- Bytes.readFile "tools/fixtures/output-guest/plugins/config/local-file.dhall"
  manifest <- Bytes.readFile "tools/fixtures/output-guest/kb.dhall"
  code <- right (fileTree ([(path "kb.dhall",manifest),(path "flake.nix","{}"),(path "flake.lock","{}"),(path "plugins/config/local-file.dhall",configuration)] ++
    [(path ("plugins/packages/local-file/source/" ++ relativeName name),bytes) | (name,bytes) <- files package]))
  withSystemTempDirectory "kyyn-output-test" $ \directory -> do
    scope <- right (directoryScope directory)
    result <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection
      . interpret @GuestCompilation (\_ (CompileGuest source) ->
          if selectedBuild source == RootEntries then pure (Right program) else error "Root preparation selected a separate plugin build")
      . runPluginPreparation . runRootStore . runRootExecution . runDelivery scope $ runExceptT $ do
        description <- ExceptT (describeGuest program)
        schema <- case [selected.contract | G.ValidatorEntry _ selected <- checkedEntries description] of
          [selected] -> ExceptT (pure (checkRootLayout selected))
          _ -> throwE [errorDiagnostic "test.root" "Missing Root validator"]
        let fact identity = object ["id" .= (identity :: String),"value" .= object ["amount" .= ("1.25" :: String)]]
            value = object ["items" .= [fact "one",fact "two"]]
        root <- ExceptT (materializeRoot schema code (R.KnowledgeBase (CheckedValue
          (contractId (rootSchema schema)) value) []))
        prepared <- ExceptT (prepareRoot root)
        ValidationReport diagnostics <- ExceptT (validateRoot prepared)
        unless (null diagnostics) (throwE diagnostics)
        case [query | query@(QueryDescriptor name _ _ _) <- preparedQueries prepared, name == "count"] of
          [query@(QueryDescriptor _ _ input _)] -> do
            QueryResult (CheckedValue _ result) trace <- ExceptT (queryRoot prepared query (CheckedValue (contractId input) (object [])))
            unless (trace == [CollectionRead "items-é"]) (throwE [errorDiagnostic "test.trace" "Wrong query trace"])
            case preparedOutputs prepared of
              [PreparedOutput _ _ selected@(ConfiguredConnector _ _ PreparedSinkConnector {sinkDefaultOptions = defaults,sinkInputContract = sinkInput} _)] ->
                ExceptT (Right <$> invokeSink selected defaults (CheckedValue (contractId sinkInput) result))
              _ -> throwE [errorDiagnostic "test.output" "Missing prepared output"]
          _ -> throwE [errorDiagnostic "test.query" "Missing prepared query"]
    outcome <- right =<< right result
    unless (case outcome of Acknowledged (CheckedValue _ (String "15")) -> True; _ -> False)
      (fail ("Output delivery failed: " ++ show outcome))
  putStrLn "Root query, read trace and typed sink publication pass through the same guest."

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
