-- Host preparation against a real Nix-built plugin-only executable. Compilation
-- is fixed to that supplied artifact and asserts PluginEntries selection; Nix
-- source capture/build itself is covered by NixGuestBuildTests. No provider runs; captured-read and sink brokers use the checked handles.
{-# LANGUAGE GHC2021, GADTs, OverloadedStrings, OverloadedRecordDot, DataKinds, TypeFamilies #-}
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (Value(..), object)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, DispatchOf, Dispatch(..), runEff)
import Effectful.Dispatch.Dynamic (interpret)
import GHC.Records (getField)
import System.Directory (canonicalizePath)
import System.Environment (getArgs)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Domain.Contract (contractId)
import Kyyn.Domain.Evidence (EvidenceSnapshotRef(..), ConnectorInstanceRef(..), EvidenceProducer(..), FetchId(..), FetchSummary(..))
import Kyyn.Domain.EvidenceIndex (EvidenceIndex(EvidenceIndex))
import Kyyn.Domain.Output (PublicationOutcome(..))
import Kyyn.Plumbing.Capability.BlobStorage (BlobStorage)
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore)
import Kyyn.Porcelain.Capability.Delivery (invokeSink)
import Kyyn.Porcelain.Interpreter.Delivery (runDelivery)
import Kyyn.Porcelain.Protocol.PluginBroker (executeCapturedRead)
import Kyyn.Domain.CompiledEntry (entryProgram)
import Kyyn.Domain.Diagnostic (ValidationReport(..))
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.Path
import Kyyn.Domain.Plugin (packageIdentity)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestInspection (describeGuest)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Interpreter.GuestInspection (runGuestInspection)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)

main :: IO ()
main = do
  arguments <- getArgs
  executable <- case arguments of
    [selected] -> canonicalizePath selected
    _ -> fail "Expected a Nix-built plugin-only executable"
  let path = either error id . relativePath
      fixture = "tools/fixtures/captured-plugin/"
  package <- mapM (\name -> (,) (path name) <$> Bytes.readFile (fixture ++ name))
    ["kyyn-plugin.dhall","src/Fixture/Plugin.hs"] >>= right . fileTree
  reordered <- right (fileTree (reverse (files package)))
  changed <- right (fileTree [(name,bytes <> "\n") | (name,bytes) <- files package])
  unless (packageIdentity package == packageIdentity reordered && packageIdentity package /= packageIdentity changed)
    (fail "Package provenance depends on traversal order or ignores changed content")
  let configuration = Text.encodeUtf8 (Text.unlines
        ["let Connector = < Files : Integer | Options : Integer | State : Integer | StateOptions : Integer | Writer : Integer >",
         "in [ { name = \"reader\", binding = \"files\", connector = Connector.Files +10 }",
         "   , { name = \"writer\", binding = \"writer\", connector = Connector.Writer +10 } ]"])
  code <- right (fileTree
    ([(path "flake.nix","{}"),(path "flake.lock","{}"),(path "kb.dhall","unfinished manifest"),
      (path "src/Main.hs","unfinished Root"),(path "plugins/config/local-file.dhall",configuration)] ++
     [(path ("plugins/packages/local-file/source/" ++ relativeName name),bytes) | (name,bytes) <- files package]))
  captured <- right (guestSources PluginEntries (files code))
  let program = CompiledProgram
        (BuildIdentity (sourceIdentity captured) "x86_64-linux" "fixture.drv" (takeDirectory (takeDirectory executable)))
        executable ".build/plugin-selection"
  withSystemTempDirectory "kyyn-plugin-preparation" $ \directory -> do
    scope <- right (directoryScope directory)
    let run action = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
          . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection . fixedCompilation program
          . runPluginPreparation $ action
    prepared <- run $ do
      packages <- preparePackages code
      plugins <- preparePlugins code
      reports <- case plugins of
        Left problems -> pure (Left problems)
        Right selected -> validatePlugins selected
      inspected <- describeGuest program
      attached <- case inspected of
        Left problems -> pure (Left problems)
        Right description -> preparePluginsFromGuest code program description
      pure (packages,plugins,reports,attached)
    (packageResult,pluginResult,reportResult,attachedResult) <- right prepared
    packages <- right packageResult
    plugins <- right pluginResult
    attached <- right attachedResult
    unless (attached == plugins) (fail "Reusing a checked guest changed prepared plugins")
    ValidationReport report <- right reportResult
    connectors <- case packages of
      [PreparedPackage _ identity selected] | identity == packageIdentity package -> pure selected
      _ -> fail "Prepared package provenance changed"
    unless (length connectors == 5) (fail "Missing prepared connector")
    let handles = concatMap (\connector -> getField @"validationEntry" connector : case connector of
          PreparedConnector {fetchEntry = fetch,loginEntry = login,methods = methods} ->
            fetch : maybe [] pure login ++ [entry | PreparedMethod _ _ _ _ entry <- methods]
          PreparedSinkConnector {sinkEntry = publish} -> [publish]) connectors
    unless (all ((== program) . entryProgram) handles) (fail "Preparation changed the described executable")
    case [value | PreparedSinkConnector {sinkDefaultOptions = CheckedValue _ value} <- connectors] of
      [String "3"] -> pure ()
      _ -> fail "Sink defaults did not use the checked guest entry"
    unless (sum [length instances | PreparedPlugin _ instances <- plugins] == 2) (fail "Configured instances missing")
    unless (null report) (fail "Configuration validation failed")
    (plugin,payload,method) <- case [(name,selected,method) |
      PreparedPackage name _ values <- packages,
      PreparedConnector {payloadContract = selected, methods = method : _} <- values] of
        [selected] -> pure selected
        _ -> fail "Missing captured method"
    let fetchId = FetchId "fixture"
        snapshot = EvidenceSnapshotRef (ConnectorInstanceRef plugin "reader")
          (EvidenceProducer (packageIdentity package) (contractId payload)) fetchId
        index = EvidenceIndex snapshot (FetchSummary fetchId "now" 0 0 0 Nothing) payload mempty Nothing
        PreparedMethod _ _ input output selected = method
    readResult <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . unexpected @BlobStorage . unexpected @EvidenceStore $
        executeCapturedRead selected (CheckedValue (contractId input) (object [])) index output
    case readResult of
      Right (Right (Right (String "0"))) -> pure ()
      other -> fail ("Native captured-read broker failed: " ++ show other)
    (writer,defaults,inputContract) <- case [(instanceValue,defaults,inputContract) |
      PreparedPlugin _ instances <- plugins,
      instanceValue@(ConfiguredConnector _ _ PreparedSinkConnector {sinkDefaultOptions = defaults,sinkInputContract = inputContract} _) <- instances] of
        [selectedWriter] -> pure selectedWriter
        _ -> fail "Missing configured writer"
    published <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runDelivery scope $
        invokeSink writer defaults (CheckedValue (contractId inputContract) (String "7"))
    case published of
      Right (Acknowledged (CheckedValue _ (String "20"))) -> pure ()
      other -> fail ("Native sink broker failed: " ++ show other)
  putStrLn "Native plugin preparation, captured-read callbacks and sink publication pass with checked entries."

fixedCompilation :: CompiledProgram -> Eff (GuestCompilation : es) a -> Eff es a
fixedCompilation program = interpret $ \_ (CompileGuest source) ->
  if selectedBuild source == PluginEntries && sourceIdentity source == program.identity.sourcesDigest
    then pure (Right program)
    else error "Preparation selected the wrong captured guest build"

unexpected :: DispatchOf effect ~ Dynamic => Eff (effect : es) a -> Eff es a
unexpected = interpret (\_ _ -> error "Unexpected external interaction in pure fixture")

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
