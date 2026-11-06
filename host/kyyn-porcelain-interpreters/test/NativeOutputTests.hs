-- Real Nix Root guest: query, read trace, checked output binding and sink delivery
-- share one executable. Compilation is not mocked or exercised by this harness;
-- the supplied artifact was built by the output fixture's Nix derivation.
{-# LANGUAGE GHC2021, OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (Value(..), object, (.=), toJSON)
import qualified Data.ByteString as Bytes
import Effectful (runEff)
import System.Directory (canonicalizePath)
import System.Environment (getArgs)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Domain.CompiledEntry (compiledEntries, entryDescription)
import Kyyn.Domain.CompiledProgram (CompiledProgram(..), BuildIdentity(..))
import Kyyn.Domain.Guest (InspectedSchema(..))
import Kyyn.Domain.Contract (contractId)
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.Path
import Kyyn.Domain.Output (OutputDefinition(..), SinkReference(..), PublicationOutcome(..))
import Kyyn.Domain.Plugin (pluginName, connectorName, methodName)
import Kyyn.Domain.Query (QueryDescriptor(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.Query (ReadAccess(..))
import qualified Kyyn.Types.Guest as G
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation)
import Kyyn.Plumbing.Capability.GuestInspection (describeGuest)
import Kyyn.Plumbing.Capability.GuestExecution (executeEntry)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Interpreter.GuestInspection (runGuestInspection)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Protocol.Query (decodeQueryReply)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.Delivery (invokeSink)
import Kyyn.Porcelain.Interpreter.Delivery (runDelivery)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Protocol.OutputBindings (prepareOutputs)
import Kyyn.Porcelain.RootExecution.Types (PreparedQuery(..), PreparedOutput(..))
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
  code <- right (fileTree ((path "plugins/config/local-file.dhall",configuration) :
    [(path ("plugins/packages/local-file/source/" ++ relativeName name),bytes) | (name,bytes) <- files package]))
  plugin <- right (pluginName "local-file")
  writer <- right (connectorName "writer")
  publish <- right (methodName "publish")
  withSystemTempDirectory "kyyn-output-test" $ \directory -> do
    scope <- right (directoryScope directory)
    result <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection
      . interpret @GuestCompilation (\_ _ -> error "Output preparation must not compile another guest")
      . runPluginPreparation . runDelivery scope $ do
        inspected <- describeGuest program
        case inspected of
          Left problems -> pure (Left (show problems))
          Right description -> do
            prepared <- preparePluginsFromGuest code program description
            case prepared of
              Left problems -> pure (Left (show problems))
              Right plugins -> case [PreparedQuery (QueryDescriptor "count" "Count stored facts" input.contract output.contract) "count" entry |
                entry <- compiledEntries program description,
                G.QueryEntry "count" (G.QueryContracts _ input output) <- [entryDescription entry]] of
                  [query@(PreparedQuery _ _ entry)] -> case prepareOutputs [query] plugins
                    [OutputDefinition "snapshot" "Publish count" "count" (SinkReference plugin writer publish)] of
                      Right [PreparedOutput _ _ selected@(ConfiguredConnector _ _ PreparedSinkConnector {sinkDefaultOptions = defaults,sinkInputContract = input} _)] -> do
                        let fact identity = object ["id" .= (identity :: String),"value" .= object ["amount" .= ("1.25" :: String)]]
                        bytes <- executeEntry entry (toJSON (G.QueryInvocation (object ["items" .= [fact "one",fact "two"]]) (object [])))
                        case decodeQueryReply bytes of
                          Right (value,[CollectionRead "items-é"]) -> Right <$> invokeSink selected defaults (CheckedValue (contractId input) value)
                          other -> pure (Left ("Unexpected query result: " ++ show other))
                      other -> pure (Left ("Output binding failed: " ++ show other))
                  _ -> pure (Left "Missing checked query")
    outcome <- right =<< right result
    unless (case outcome of Acknowledged (CheckedValue _ (String "15")) -> True; _ -> False)
      (fail ("Output delivery failed: " ++ show outcome))
  putStrLn "Root query, read trace and typed sink publication pass through the same guest."

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
