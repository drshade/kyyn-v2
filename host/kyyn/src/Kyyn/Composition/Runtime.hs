{-# LANGUAGE DataKinds #-}
module Kyyn.Composition.Runtime (Base, Runtime, runBase, runRuntime, withRuntime, finish) where

import Effectful (Eff, IOE, runEff)
import System.Directory (findExecutable, canonicalizePath)
import qualified Data.ByteString.Char8 as Bytes
import Kyyn.Configuration (Host(..))
import Kyyn.Composition.Timings
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Domain.Path (scopePath)
import Kyyn.Plumbing.Interpreter.GuestCompilation (GuestBuildEnvironment(..), runGuestCompilation)
import Kyyn.Plumbing.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Interpreter.SchemaInspection (runSchemaInspection)
import Kyyn.Plumbing.Interpreter.GuestInspection (runGuestInspection)
import Kyyn.Plumbing.Capability.GuestInspection (GuestInspection)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Capability.Git (Git)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExecution)
import qualified Kyyn.Plumbing.Capability.ProcessExecution as Process
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.Git (runGit)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Porcelain.Capability.RootStore (RootStore)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Surfaces.Result (Response, operationalFailure, refusal)

type Base = '[RootStore, DhallHandling, Git, FileSystem, ProcessExecution, Failure, IOE]
type Runtime = SchemaInspection ': GuestInspection ': GuestCompilation ': GuestExecution ': Base

runBase :: Host -> Eff Base a -> IO (Either OperationalFailure a)
runBase (Host executable environment temp _ _ _ _) = runEff . runFailure . runProcessExecutionIO
  . runFileSystemIO temp . runGit executable environment . runDhallHandling . runRootStore

runRuntime :: Host -> GuestBuildEnvironment -> Eff Runtime a -> IO (Either OperationalFailure a)
runRuntime host@(Host _ _ _ _ _ environment timings) settings = runBase host
  . runGuestExecution environment . observeExecutions timings
  . runGuestCompilation settings . observeCompilations timings . runGuestInspection . runSchemaInspection

finish :: IO (Either OperationalFailure Response) -> IO Response
finish action = either operationalFailure id <$> action

withRuntime :: Host -> (GuestBuildEnvironment -> IO Response) -> IO Response
withRuntime host@(Host _ _ temp override cache environment _) action = do
  located <- findExecutable (maybe "nix" id override)
  case located of
    Nothing -> pure (refusal [errorDiagnostic "setup.nix" "Nix was not found; install Nix or supply --nix EXECUTABLE"])
    Just path -> do
      executable <- canonicalizePath path
      result <- runBase host $ Process.withProcess
        (Process.ProcessSpec executable ["--extra-experimental-features","nix-command flakes","eval","--impure","--raw","--expr","builtins.currentSystem"]
          (scopePath temp) environment) $ do
          Process.closeStdin
          output <- Process.collectStdout
          status <- Process.awaitExit
          pure (output,status)
      case result of
        Left failure -> pure (operationalFailure failure)
        Right (output,Process.ProcessExit 0 _) | not (Bytes.null output) ->
          action (GuestBuildEnvironment executable (Bytes.unpack output) environment cache)
        Right (_,Process.ProcessExit _ errors) -> pure (refusal [errorDiagnostic "setup.nix" (Bytes.unpack errors)])
