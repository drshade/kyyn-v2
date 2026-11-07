-- Actual Root-built tool and nested captured-method subprocesses. The supplied
-- Nix executable is fixed by the compilation interpreter, which rejects plugin
-- selection. Evidence is empty and already captured; no provider/model is used.
{-# LANGUAGE GHC2021, GADTs, OverloadedStrings, OverloadedRecordDot, DataKinds, TypeFamilies #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value(..), object)
import qualified Data.ByteString as Bytes
import Effectful (Eff, DispatchOf, Dispatch(..), runEff)
import Effectful.Dispatch.Dynamic (interpret)
import GHC.Records (getField)
import System.Directory (canonicalizePath)
import System.Environment (getArgs)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Kyyn.Domain.Contract (contractId)
import Kyyn.Domain.CompiledEntry (entryProgram)
import Kyyn.Domain.Evidence (EvidenceSnapshotRef(..), ConnectorInstanceRef(..), EvidenceProducer(..), FetchId(..), FetchSummary(..))
import Kyyn.Domain.EvidenceIndex (EvidenceIndex(EvidenceIndex))
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.Path
import Kyyn.Domain.Plugin (packageIdentity, ConnectorTypeName(..))
import Kyyn.Domain.Tool (ToolDescriptor(..))
import Kyyn.Plumbing.Capability.BlobStorage (BlobStorage)
import Kyyn.Plumbing.Capability.Judgement (Judgement)
import Kyyn.Plumbing.Capability.ModelTurn (ModelTurn)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Interpreter.GuestInspection (runGuestInspection)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Capability.Tool
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.PluginRead (runPluginRead)
import Kyyn.Porcelain.Protocol.ToolBroker (executeToolProgramCaptured)

main :: IO ()
main = do
  arguments <- getArgs
  executable <- case arguments of
    [selected] -> canonicalizePath selected
    _ -> fail "Expected a Nix-built Root tool executable"
  let path = either error id . relativePath
  package <- mapM (\name -> (,) (path name) <$> Bytes.readFile ("tools/fixtures/captured-plugin/" ++ name))
    ["kyyn-plugin.dhall","src/Fixture/Plugin.hs"] >>= right . fileTree
  configuration <- Bytes.readFile "tools/fixtures/tool-guest/plugins/config/local-file.dhall"
  code <- right (fileTree
    ([(path "flake.nix","{}"),(path "flake.lock","{}"),(path "plugins/config/local-file.dhall",configuration)] ++
     [(path ("plugins/packages/local-file/source/" ++ relativeName name),bytes) | (name,bytes) <- files package]))
  captured <- right (guestSources RootEntries (files code))
  let program = CompiledProgram
        (BuildIdentity (sourceIdentity captured) "x86_64-linux" "fixture.drv" (takeDirectory (takeDirectory executable)))
        executable ".build/grouped-guests"
  withSystemTempDirectory "kyyn-tool-preparation" $ \directory -> do
    scope <- right (directoryScope directory)
    prepared <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
      . runGuestExecution [("LC_ALL","C.UTF-8")] . runGuestInspection . fixedCompilation program
      . runPluginPreparation . runToolPreparation $ prepareTools code
    tools <- right =<< right prepared
    unless (length tools == 2) (fail "Missing prepared tools")
    forM_ tools $ \(PreparedTool (ToolDescriptor name _ _ _) entry plugins model) -> do
      let handles = entry : concat [getField @"validationEntry" connector : case connector of
            PreparedConnector {fetchEntry = fetch,loginEntry = login,methods = methods} ->
              fetch : maybe [] pure login ++ [method | PreparedMethod _ _ _ _ method <- methods]
            PreparedSinkConnector {sinkEntry = publish} -> [publish] |
            PreparedPlugin (PreparedPackage _ _ connectors) _ <- plugins, connector <- connectors]
      unless (all ((== program) . entryProgram) handles) (fail "Tool and plugin handles refer to different builds")
      (plugin,payload) <- case [(plugin,payload) | PreparedPlugin (PreparedPackage plugin _ connectors) _ <- plugins,
        PreparedConnector {connectorType = ConnectorTypeName "Files",payloadContract = payload} <- connectors] of
          [selected] -> pure selected
          _ -> fail "Missing tool connector"
      let fetchId = FetchId "fixture"
          snapshot = EvidenceSnapshotRef (ConnectorInstanceRef plugin "reader")
            (EvidenceProducer (packageIdentity package) (contractId payload)) fetchId
          index = EvidenceIndex snapshot (FetchSummary fetchId "now" 0 0 0 Nothing) payload mempty Nothing
      result <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runDhallHandling
        . runGuestExecution [("LC_ALL","C.UTF-8")] . unexpected @Judgement . unexpected @ModelTurn
        . unexpected @BlobStorage . unexpected @EvidenceStore . runPluginRead $
          executeToolProgramCaptured entry plugins model [index] (object [])
      case result of
        Right (Right (String "0",[actual])) | actual == index -> pure ()
        other -> fail ("Native tool " ++ show name ++ " failed: " ++ show other)
  putStrLn "Root tools and nested captured reads run through one checked guest build."

fixedCompilation :: CompiledProgram -> Eff (GuestCompilation : es) a -> Eff es a
fixedCompilation program = interpret $ \_ (CompileGuest source) ->
  if selectedBuild source == RootEntries && sourceIdentity source == program.identity.sourcesDigest
    then pure (Right program)
    else error "Tool preparation attempted a separate plugin build"

unexpected :: DispatchOf effect ~ Dynamic => Eff (effect : es) a -> Eff es a
unexpected = interpret (\_ _ -> error "Unexpected external interaction in fixture")

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
